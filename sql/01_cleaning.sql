-- =====================================================================
-- Project 1: National Services Performance Scorecard
-- 01_cleaning.sql  (BigQuery Standard SQL)
--
-- Run each statement separately in the BigQuery console.
-- If you get "dataset not found", prefix the dataset with your project:
--   `your-project-id.contact_centre.interactions_raw`
--
-- Data is SYNTHETIC. Raw tables are never modified; all cleaning happens in views.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1: staging view. Dedupe, standardise labels, fix time grain, flag bad values.
-- Rule: never silently delete. Flag, then let downstream KPIs exclude by a stated rule.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW contact_centre.stg_interactions AS
WITH deduped AS (
  -- Duplicate rule: same interaction_id + received_at = same event logged twice.
  -- Keep the primary system's row over the LegacyCRM copy.
  SELECT * EXCEPT (rn)
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY interaction_id, received_at
        ORDER BY CASE WHEN source_system = 'LegacyCRM' THEN 1 ELSE 0 END
      ) AS rn
    FROM contact_centre.interactions_raw
  )
  WHERE rn = 1
),

standardised AS (
  SELECT
    interaction_id,
    source_system,

    -- Jurisdiction: map every spelling to one name. Anything unmapped is surfaced, not hidden.
    CASE
      WHEN LOWER(TRIM(jurisdiction)) IN ('criminal fines', 'crim fines', 'cf')
        THEN 'Criminal Fines'
      WHEN LOWER(TRIM(jurisdiction)) IN ('collection & enforcement', 'collection and enforcement', 'c&e', 'ce')
        THEN 'Collection & Enforcement'
      WHEN LOWER(TRIM(jurisdiction)) IN ('national business centres', 'national business centre', 'nbc')
        THEN 'National Business Centres'
      WHEN LOWER(TRIM(jurisdiction)) IN ('courts & tribunals service centres', 'courts and tribunals service centre', 'ctsc')
        THEN 'Courts & Tribunals Service Centres'
      ELSE 'UNMAPPED'
    END AS jurisdiction,

    -- Channel: same idea
    CASE
      WHEN LOWER(TRIM(channel)) IN ('voice', 'phone') THEN 'voice'
      WHEN LOWER(TRIM(channel)) IN ('webchat', 'web chat') THEN 'webchat'
      WHEN LOWER(TRIM(channel)) IN ('email', 'e-mail') THEN 'email'
      WHEN LOWER(TRIM(channel)) = 'admin' THEN 'admin'
      ELSE 'UNMAPPED'
    END AS channel,

    outcome,
    NULLIF(TRIM(agent_id), '') AS agent_id,
    queue_wait_seconds,
    handle_seconds,

    -- Time grain: voice/webchat have a timestamp, email/admin only a date.
    -- Everything gets a received_date. Only timed channels get a timestamp and 30-min interval.
    SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(received_at, 1, 10)) AS received_date,
    SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', received_at) AS received_ts,
    SAFE.PARSE_DATE('%Y-%m-%d', completed_at) AS completed_date
  FROM deduped
)

SELECT
  *,
  -- 30-minute interval start (NULL for email/admin, which have no time of day)
  TIMESTAMP_SECONDS(1800 * DIV(UNIX_SECONDS(received_ts), 1800)) AS interval_start,

  -- Short abandon rule: abandoned within 5 seconds. Excluded from abandonment and service level.
  (outcome = 'Abandoned' AND queue_wait_seconds < 5) AS is_short_abandon,

  -- Handle time quality. Only meaningful where work was actually handled.
  -- Upper bound 7,200s (2h): real values in this data peak near 6,000s; the 9h rows are errors.
  CASE
    WHEN outcome NOT IN ('Answered', 'Completed') THEN 'n/a'
    WHEN handle_seconds IS NULL THEN 'missing'
    WHEN handle_seconds <= 0 THEN 'zero'
    WHEN handle_seconds > 7200 THEN 'too_long'
    ELSE 'ok'
  END AS handle_quality,

  (outcome IN ('Answered', 'Completed') AND agent_id IS NULL) AS is_missing_agent
FROM standardised;


-- ---------------------------------------------------------------------
-- STEP 2: materialise the clean table (Power BI and later KPI views read this).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE contact_centre.interactions_clean AS
SELECT * FROM contact_centre.stg_interactions;


-- ---------------------------------------------------------------------
-- STEP 3: data quality audit. Paste these numbers into your README as the cleaning log.
-- ---------------------------------------------------------------------
SELECT check_name, n
FROM (
  SELECT 1 AS ord, 'raw rows loaded' AS check_name, COUNT(*) AS n
  FROM contact_centre.interactions_raw
  UNION ALL
  SELECT 2, 'duplicate rows removed',
    (SELECT COUNT(*) FROM contact_centre.interactions_raw) - (SELECT COUNT(*) FROM contact_centre.interactions_clean)
  UNION ALL
  SELECT 3, 'rows after dedupe', COUNT(*) FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 4, 'unmapped jurisdiction labels', COUNTIF(jurisdiction = 'UNMAPPED') FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 5, 'unmapped channel labels', COUNTIF(channel = 'UNMAPPED') FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 6, 'handled rows missing agent_id', COUNTIF(is_missing_agent) FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 7, 'handled rows missing handle_seconds', COUNTIF(handle_quality = 'missing') FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 8, 'handled rows with zero handle_seconds', COUNTIF(handle_quality = 'zero') FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 9, 'handled rows over 7,200s', COUNTIF(handle_quality = 'too_long') FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 10, 'short abandons (<5s), excluded from rates', COUNTIF(is_short_abandon) FROM contact_centre.interactions_clean
  UNION ALL
  SELECT 11, 'email/admin items still open', COUNTIF(outcome = 'Open') FROM contact_centre.interactions_clean
)
ORDER BY ord;


-- ---------------------------------------------------------------------
-- STEP 4: sanity checks. Expect no UNMAPPED, and four jurisdictions x four channels.
-- ---------------------------------------------------------------------
SELECT jurisdiction, channel, COUNT(*) AS rows_n
FROM contact_centre.interactions_clean
GROUP BY jurisdiction, channel
ORDER BY jurisdiction, channel;

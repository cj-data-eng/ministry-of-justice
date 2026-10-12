-- =====================================================================
-- Project 1: National Services Performance Scorecard
-- 02_kpis.sql  (BigQuery Standard SQL)
--
-- Run each statement separately in the BigQuery console, in order.
--
-- DESIGN RULE: store numerators and denominators, not just percentages.
-- You cannot average percentages across days or teams (a quiet day would count the
-- same as a busy one). Power BI sums the numerators and denominators, then divides.
--
-- KPI DEFINITIONS (write these in your README, interviewers will probe them)
--   Offered (voice/webchat)  = contacts reaching the queue, excluding short abandons (<5s)
--   Answer rate              = answered / offered
--   Abandonment rate         = abandoned (after 5s) / offered
--   Service level            = answered within threshold / offered
--                              (voice 20s, webchat 30s; target 80%)
--   AHT                      = total valid handle seconds / count of valid handled contacts
--                              (valid = handle_quality 'ok': not missing, zero or over 2h)
--   Received / Completed     = email and admin items in / out per day
--   Closing backlog          = cumulative received - cumulative completed at end of day
--   Turnaround rate          = completed within target working days / completed
--                              (email 2 working days, admin 5; target 90%)
--   Occupancy                = valid handle minutes / available minutes
--   Adherence                = in-adherence minutes / scheduled work minutes
--                              (absence days are excluded from the denominator)
--   Shrinkage                = (absence + break minutes) / scheduled minutes
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1: working-day calendar (turnaround is measured in WORKING days, not calendar days)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW contact_centre.dim_working_days AS
SELECT
  work_date,
  ROW_NUMBER() OVER (ORDER BY work_date) AS wd_index
FROM (SELECT DISTINCT date AS work_date FROM contact_centre.agent_daily);


-- ---------------------------------------------------------------------
-- STEP 2: main KPI fact table. Grain = one row per date x jurisdiction x channel.
-- Realtime metrics (voice/webchat) are NULL for email/admin and vice versa.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE contact_centre.fact_kpi_daily AS
WITH
spine AS (
  SELECT d.work_date, g.jurisdiction, g.channel
  FROM contact_centre.dim_working_days d
  CROSS JOIN (
    SELECT DISTINCT jurisdiction, primary_channel AS channel FROM contact_centre.agents
  ) g
),

realtime AS (
  SELECT
    i.received_date AS work_date,
    i.jurisdiction,
    i.channel,
    COUNTIF(NOT i.is_short_abandon) AS offered,
    COUNTIF(i.outcome = 'Answered') AS answered,
    COUNTIF(i.outcome = 'Abandoned' AND NOT i.is_short_abandon) AS abandoned,
    COUNTIF(i.outcome = 'Answered'
            AND i.queue_wait_seconds <= t.service_level_threshold_seconds) AS answered_in_threshold,
    COUNTIF(i.outcome = 'Answered' AND i.handle_quality = 'ok') AS valid_handle_count,
    SUM(IF(i.outcome = 'Answered' AND i.handle_quality = 'ok', i.handle_seconds, 0)) AS valid_handle_seconds
  FROM contact_centre.interactions_clean i
  JOIN contact_centre.targets t ON t.channel = i.channel
  WHERE i.channel IN ('voice', 'webchat')
  GROUP BY 1, 2, 3
),

received AS (
  SELECT received_date AS work_date, jurisdiction, channel, COUNT(*) AS received
  FROM contact_centre.interactions_clean
  WHERE channel IN ('email', 'admin')
  GROUP BY 1, 2, 3
),

completed AS (
  SELECT
    i.completed_date AS work_date,
    i.jurisdiction,
    i.channel,
    COUNT(*) AS completed,
    COUNTIF(wc.wd_index - wr.wd_index <= t.turnaround_target_days) AS completed_in_target
  FROM contact_centre.interactions_clean i
  JOIN contact_centre.dim_working_days wr ON wr.work_date = i.received_date
  JOIN contact_centre.dim_working_days wc ON wc.work_date = i.completed_date
  JOIN contact_centre.targets t ON t.channel = i.channel
  WHERE i.outcome = 'Completed'
  GROUP BY 1, 2, 3
),

capacity AS (
  SELECT
    ad.date AS work_date,
    a.jurisdiction,
    a.primary_channel AS channel,
    SUM(ad.scheduled_minutes) AS scheduled_minutes,
    SUM(ad.absence_minutes) AS absence_minutes,
    SUM(ad.break_minutes) AS break_minutes,
    SUM(ad.available_minutes) AS available_minutes,
    SUM(ad.scheduled_work_minutes) AS scheduled_work_minutes,
    SUM(ad.in_adherence_minutes) AS in_adherence_minutes
  FROM contact_centre.agent_daily ad
  JOIN contact_centre.agents a ON a.agent_id = ad.agent_id
  GROUP BY 1, 2, 3
),

workload AS (
  -- Voice/webchat work happens on the received date; email/admin work on the completed date.
  SELECT
    IF(channel IN ('voice', 'webchat'), received_date, completed_date) AS work_date,
    jurisdiction,
    channel,
    SUM(handle_seconds) / 60 AS handle_minutes
  FROM contact_centre.interactions_clean
  WHERE handle_quality = 'ok'
  GROUP BY 1, 2, 3
)

SELECT
  s.work_date,
  s.jurisdiction,
  s.channel,

  -- realtime numerators / denominators and rates
  r.offered,
  r.answered,
  r.abandoned,
  r.answered_in_threshold,
  r.valid_handle_count,
  r.valid_handle_seconds,
  SAFE_DIVIDE(r.answered, r.offered) AS answer_rate,
  SAFE_DIVIDE(r.abandoned, r.offered) AS abandonment_rate,
  SAFE_DIVIDE(r.answered_in_threshold, r.offered) AS service_level,
  SAFE_DIVIDE(r.valid_handle_seconds, r.valid_handle_count) AS aht_seconds,

  -- email / admin flow and backlog
  rc.received,
  c.completed,
  c.completed_in_target,
  SAFE_DIVIDE(c.completed_in_target, c.completed) AS turnaround_rate,
  IF(s.channel IN ('email', 'admin'),
     SUM(IFNULL(rc.received, 0)) OVER (PARTITION BY s.jurisdiction, s.channel ORDER BY s.work_date
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
     - SUM(IFNULL(c.completed, 0)) OVER (PARTITION BY s.jurisdiction, s.channel ORDER BY s.work_date
                                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
     NULL) AS closing_backlog,

  -- capacity, adherence, occupancy, shrinkage
  cap.scheduled_minutes,
  cap.absence_minutes,
  cap.break_minutes,
  cap.available_minutes,
  cap.scheduled_work_minutes,
  cap.in_adherence_minutes,
  w.handle_minutes,
  SAFE_DIVIDE(w.handle_minutes, cap.available_minutes) AS occupancy,
  SAFE_DIVIDE(cap.in_adherence_minutes, cap.scheduled_work_minutes) AS adherence,
  SAFE_DIVIDE(cap.absence_minutes + cap.break_minutes, cap.scheduled_minutes) AS shrinkage
FROM spine s
LEFT JOIN realtime r ON r.work_date = s.work_date AND r.jurisdiction = s.jurisdiction AND r.channel = s.channel
LEFT JOIN received rc ON rc.work_date = s.work_date AND rc.jurisdiction = s.jurisdiction AND rc.channel = s.channel
LEFT JOIN completed c ON c.work_date = s.work_date AND c.jurisdiction = s.jurisdiction AND c.channel = s.channel
LEFT JOIN capacity cap ON cap.work_date = s.work_date AND cap.jurisdiction = s.jurisdiction AND cap.channel = s.channel
LEFT JOIN workload w ON w.work_date = s.work_date AND w.jurisdiction = s.jurisdiction AND w.channel = s.channel;


-- ---------------------------------------------------------------------
-- STEP 3: agent-level daily scorecard (feeds the team leader coaching page)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE contact_centre.fact_agent_daily AS
SELECT
  ad.date AS work_date,
  ad.agent_id,
  a.team_id,
  a.team_leader_id,
  a.jurisdiction,
  a.primary_channel AS channel,
  ad.absence_reason,
  ad.available_minutes,
  ad.scheduled_work_minutes,
  ad.in_adherence_minutes,
  ad.qa_score,
  IFNULL(w.handled_count, 0) AS handled_count,
  IFNULL(w.valid_handle_count, 0) AS valid_handle_count,
  IFNULL(w.valid_handle_seconds, 0) AS valid_handle_seconds
FROM contact_centre.agent_daily ad
JOIN contact_centre.agents a ON a.agent_id = ad.agent_id
LEFT JOIN (
  SELECT
    IF(channel IN ('voice', 'webchat'), received_date, completed_date) AS work_date,
    agent_id,
    COUNTIF(outcome IN ('Answered', 'Completed')) AS handled_count,
    COUNTIF(handle_quality = 'ok') AS valid_handle_count,
    SUM(IF(handle_quality = 'ok', handle_seconds, 0)) AS valid_handle_seconds
  FROM contact_centre.interactions_clean
  WHERE agent_id IS NOT NULL AND outcome IN ('Answered', 'Completed')
  GROUP BY 1, 2
) w ON w.work_date = ad.date AND w.agent_id = ad.agent_id;


-- ---------------------------------------------------------------------
-- STEP 4: validation queries. Compare with the expected values supplied separately.
-- ---------------------------------------------------------------------

-- 4a. Whole-period voice and webchat KPIs (sum numerators, then divide)
SELECT
  channel,
  SUM(offered) AS offered,
  ROUND(SAFE_DIVIDE(SUM(answered_in_threshold), SUM(offered)), 4) AS service_level,
  ROUND(SAFE_DIVIDE(SUM(abandoned), SUM(offered)), 4) AS abandonment_rate,
  ROUND(SAFE_DIVIDE(SUM(valid_handle_seconds), SUM(valid_handle_count)), 1) AS aht_seconds
FROM contact_centre.fact_kpi_daily
WHERE channel IN ('voice', 'webchat')
GROUP BY channel
ORDER BY channel;

-- 4b. Backlog on the final day. Total across email + admin should equal the open items from the audit (854).
SELECT channel, SUM(closing_backlog) AS closing_backlog
FROM contact_centre.fact_kpi_daily
WHERE work_date = (SELECT MAX(work_date) FROM contact_centre.dim_working_days)
  AND channel IN ('email', 'admin')
GROUP BY channel
ORDER BY channel;

-- 4c. Whole-period capacity metrics
SELECT
  ROUND(SAFE_DIVIDE(SUM(in_adherence_minutes), SUM(scheduled_work_minutes)), 4) AS adherence,
  ROUND(SAFE_DIVIDE(SUM(absence_minutes) + SUM(break_minutes), SUM(scheduled_minutes)), 4) AS shrinkage,
  ROUND(SAFE_DIVIDE(SUM(handle_minutes), SUM(available_minutes)), 4) AS occupancy
FROM contact_centre.fact_kpi_daily;

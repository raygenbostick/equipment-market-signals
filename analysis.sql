-- Equipment Market Signals: all SQL, in the order it was run (Snowflake)
-- Raw data came from FRED CSVs loaded with Snowsight's "Load data into a table".
-- Map the file's first column (observation_date) to OBS_DATE and its second column to VALUE.

USE WAREHOUSE SNOWFLAKE_LEARNING_WH;

-- 1. Setup
CREATE DATABASE IF NOT EXISTS EQUIP_SIGNALS;
CREATE SCHEMA IF NOT EXISTS EQUIP_SIGNALS.RAW;
CREATE SCHEMA IF NOT EXISTS EQUIP_SIGNALS.CLEAN;
USE DATABASE EQUIP_SIGNALS;
USE SCHEMA EQUIP_SIGNALS.RAW;

CREATE OR REPLACE TABLE ppi_machinery (obs_date DATE, value FLOAT);
CREATE OR REPLACE TABLE ppi_steel (obs_date DATE, value FLOAT);
CREATE OR REPLACE TABLE construction_spending (obs_date DATE, value FLOAT);
CREATE OR REPLACE TABLE fed_funds (obs_date DATE, value FLOAT);

-- 2. Data-quality check: any months with blank values? (should return no rows)
SELECT YEAR(obs_date) AS yr, COUNT(*) AS rows_in_year, COUNT(value) AS non_null_values
FROM EQUIP_SIGNALS.RAW.PPI_STEEL
WHERE obs_date >= '1993-01-01'
GROUP BY 1
HAVING COUNT(*) <> COUNT(value)
ORDER BY 1;

-- 3. One monthly table with all four series
USE SCHEMA CLEAN;

CREATE OR REPLACE TABLE monthly_base AS
SELECT
  m.obs_date AS month,
  m.value    AS machinery_ppi,
  s.value    AS steel_ppi,
  c.value    AS construction_spending,
  f.value    AS fed_funds
FROM EQUIP_SIGNALS.RAW.PPI_MACHINERY m
JOIN EQUIP_SIGNALS.RAW.PPI_STEEL s              ON s.obs_date = m.obs_date
JOIN EQUIP_SIGNALS.RAW.CONSTRUCTION_SPENDING c  ON c.obs_date = m.obs_date
JOIN EQUIP_SIGNALS.RAW.FED_FUNDS f              ON f.obs_date = m.obs_date;

-- Check: n should equal expected_months (no missing months)
SELECT COUNT(*) AS n,
       MIN(month) AS first_month,
       MAX(month) AS last_month,
       DATEDIFF('month', MIN(month), MAX(month)) + 1 AS expected_months,
       COUNT(steel_ppi) AS steel_values
FROM monthly_base;

-- 4. Year-over-year changes and lagged signals
CREATE OR REPLACE TABLE monthly_features AS
WITH yoy AS (
  SELECT
    month, machinery_ppi, steel_ppi, construction_spending, fed_funds,
    (machinery_ppi / LAG(machinery_ppi, 12) OVER (ORDER BY month) - 1) * 100 AS machinery_yoy,
    (steel_ppi / LAG(steel_ppi, 12) OVER (ORDER BY month) - 1) * 100 AS steel_yoy,
    (construction_spending / LAG(construction_spending, 12) OVER (ORDER BY month) - 1) * 100 AS spending_yoy,
    fed_funds - LAG(fed_funds, 12) OVER (ORDER BY month) AS fed_funds_chg
  FROM monthly_base
)
SELECT *,
  LAG(steel_yoy, 3)  OVER (ORDER BY month) AS steel_yoy_lag3,
  LAG(steel_yoy, 6)  OVER (ORDER BY month) AS steel_yoy_lag6,
  LAG(spending_yoy, 3) OVER (ORDER BY month) AS spending_yoy_lag3,
  LAG(spending_yoy, 6) OVER (ORDER BY month) AS spending_yoy_lag6,
  LAG(fed_funds_chg, 3) OVER (ORDER BY month) AS fed_funds_chg_lag3,
  LAG(fed_funds_chg, 6) OVER (ORDER BY month) AS fed_funds_chg_lag6
FROM yoy;

-- 5. Correlations with machinery price changes, at lags 0, 3, 6 months
CREATE OR REPLACE TABLE correlations AS
WITH pairs AS (
  SELECT month, machinery_yoy AS y, 'Steel PPI' AS signal, 0 AS lag_months, steel_yoy AS x FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Steel PPI', 3, steel_yoy_lag3 FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Steel PPI', 6, steel_yoy_lag6 FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Construction spending', 0, spending_yoy FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Construction spending', 3, spending_yoy_lag3 FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Construction spending', 6, spending_yoy_lag6 FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Fed funds change', 0, fed_funds_chg FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Fed funds change', 3, fed_funds_chg_lag3 FROM monthly_features
  UNION ALL SELECT month, machinery_yoy, 'Fed funds change', 6, fed_funds_chg_lag6 FROM monthly_features
),
windows AS (
  SELECT 'All months' AS window_label, DATE '1900-01-01' AS start_date
  UNION ALL SELECT 'Since 2015', DATE '2015-01-01'
)
SELECT w.window_label, p.signal, p.lag_months,
       ROUND(CORR(p.y, p.x), 3) AS correlation,
       COUNT_IF(p.x IS NOT NULL AND p.y IS NOT NULL) AS n_months
FROM pairs p
JOIN windows w ON p.month >= w.start_date
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

SELECT signal, lag_months,
       MAX(IFF(window_label = 'All months', correlation, NULL)) AS all_months,
       MAX(IFF(window_label = 'Since 2015', correlation, NULL)) AS since_2015,
       MAX(IFF(window_label = 'Since 2015', n_months, NULL))    AS n_since_2015
FROM correlations
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6. Steel's correlation with machinery price changes at every lead time, 0 to 24 months
CREATE OR REPLACE TABLE steel_lag_profile AS
WITH lags AS (
  SELECT SEQ4() AS lag_months FROM TABLE(GENERATOR(ROWCOUNT => 25))
),
joined AS (
  SELECT l.lag_months, b.month, b.machinery_yoy, s.steel_yoy AS steel_yoy_lagged
  FROM lags l
  CROSS JOIN monthly_features b
  LEFT JOIN monthly_features s
    ON s.month = DATEADD('month', -l.lag_months, b.month)
)
SELECT lag_months,
       ROUND(CORR(machinery_yoy, steel_yoy_lagged), 3) AS all_months,
       ROUND(CORR(IFF(month >= '2015-01-01', machinery_yoy, NULL),
                  IFF(month >= '2015-01-01', steel_yoy_lagged, NULL)), 3) AS since_2015,
       COUNT_IF(machinery_yoy IS NOT NULL AND steel_yoy_lagged IS NOT NULL) AS n_months
FROM joined
GROUP BY 1;

SELECT * FROM steel_lag_profile ORDER BY lag_months;

-- 7. Robustness check: does the 12-month steel relationship hold without 2020-2024?
WITH x AS (
  SELECT month, machinery_yoy,
         LAG(steel_yoy, 12) OVER (ORDER BY month) AS steel_lag12
  FROM EQUIP_SIGNALS.CLEAN.monthly_features
)
SELECT 'All months' AS sample_label,
       ROUND(CORR(machinery_yoy, steel_lag12), 3) AS corr_lag12,
       COUNT_IF(machinery_yoy IS NOT NULL AND steel_lag12 IS NOT NULL) AS n_months
FROM x
UNION ALL
SELECT 'Excluding 2020-2024',
       ROUND(CORR(machinery_yoy, steel_lag12), 3),
       COUNT_IF(machinery_yoy IS NOT NULL AND steel_lag12 IS NOT NULL)
FROM x
WHERE month < '2020-01-01' OR month >= '2025-01-01';

-- 8. Chart 1 data: standardized year-over-year changes, steel shown 12 months earlier
WITH base AS (
  SELECT month, machinery_yoy,
         LAG(steel_yoy, 12) OVER (ORDER BY month) AS steel_yoy_lag12
  FROM EQUIP_SIGNALS.CLEAN.monthly_features
)
SELECT month,
       (machinery_yoy - AVG(machinery_yoy) OVER ()) / STDDEV(machinery_yoy) OVER () AS machinery_standardized,
       (steel_yoy_lag12 - AVG(steel_yoy_lag12) OVER ()) / STDDEV(steel_yoy_lag12) OVER () AS steel_12mo_earlier_standardized
FROM base
WHERE month >= '2005-01-01'
  AND machinery_yoy IS NOT NULL
  AND steel_yoy_lag12 IS NOT NULL
ORDER BY month;

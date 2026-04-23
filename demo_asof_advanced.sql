-- AS OF SELECT: Advanced Demo
-- Run: ./build/release/duckdb < demo_asof_advanced.sql

----------------------------------------------------------------------
-- 1. Stock prices: composite key (ticker + exchange + valid_from)
----------------------------------------------------------------------
CREATE TABLE stock_prices (
    ticker     VARCHAR   NOT NULL,
    exchange   VARCHAR   NOT NULL,
    valid_from TIMESTAMP NOT NULL,
    price      DECIMAL(10,2),
    PRIMARY KEY (ticker, exchange, valid_from)
);

-- Generate a year of daily-ish prices for a few stocks
INSERT INTO stock_prices
    SELECT ticker, exchange, ts, round(base + (random() - 0.5) * 20, 2)
    FROM (
        SELECT unnest(['AAPL','GOOG','MSFT']) AS ticker,
               unnest([150.0, 140.0, 380.0])  AS base
    ) stocks
    CROSS JOIN (VALUES ('NYSE'), ('NASDAQ')) AS ex(exchange)
    CROSS JOIN (
        SELECT unnest(generate_series('2024-01-01'::TIMESTAMP, '2024-12-31'::TIMESTAMP, INTERVAL '7 days')) AS ts
    ) dates;

.print '── Stock prices table: row count ──'
SELECT count(*) AS total_rows,
       count(DISTINCT ticker) AS tickers,
       count(DISTINCT exchange) AS exchanges,
       min(valid_from)::DATE AS first_date,
       max(valid_from)::DATE AS last_date
FROM stock_prices;

.print ''
.print '── Portfolio snapshot on 2024-03-15 ──'
SELECT ticker, exchange, valid_from::DATE AS as_of_date, price
FROM stock_prices AT(ASOF => '2024-03-15'::TIMESTAMP)
ORDER BY ticker, exchange;

.print ''
.print '── Portfolio snapshot on 2024-09-01 ──'
SELECT ticker, exchange, valid_from::DATE AS as_of_date, price
FROM stock_prices AT(ASOF => '2024-09-01'::TIMESTAMP)
ORDER BY ticker, exchange;

.print ''
.print '── Price comparison: Q1 vs Q3 ──'
SELECT
    q1.ticker,
    q1.exchange,
    q1.price AS q1_price,
    q3.price AS q3_price,
    round(q3.price - q1.price, 2) AS change,
    round((q3.price - q1.price) / q1.price * 100, 1) AS pct_change
FROM stock_prices AS q1 AT(ASOF => '2024-03-31'::TIMESTAMP)
JOIN stock_prices AS q3 AT(ASOF => '2024-09-30'::TIMESTAMP)
  ON q1.ticker = q3.ticker AND q1.exchange = q3.exchange
ORDER BY pct_change DESC;

----------------------------------------------------------------------
-- 2. Feature flags: single-entity table (PK = valid_from only)
----------------------------------------------------------------------
CREATE TABLE feature_flags (
    valid_from TIMESTAMP NOT NULL PRIMARY KEY,
    dark_mode  BOOLEAN,
    beta_ui    BOOLEAN,
    max_upload INTEGER
);

INSERT INTO feature_flags VALUES
    ('2024-01-01', false, false, 10),
    ('2024-04-01', false, true,  10),
    ('2024-07-01', true,  true,  50),
    ('2024-10-01', true,  false, 100);

.print ''
.print '── Feature flags over time ──'
SELECT '2024-02-15' AS checked_at, * FROM feature_flags AT(ASOF => '2024-02-15'::TIMESTAMP)
UNION ALL
SELECT '2024-05-01', * FROM feature_flags AT(ASOF => '2024-05-01'::TIMESTAMP)
UNION ALL
SELECT '2024-08-01', * FROM feature_flags AT(ASOF => '2024-08-01'::TIMESTAMP)
UNION ALL
SELECT '2024-11-01', * FROM feature_flags AT(ASOF => '2024-11-01'::TIMESTAMP)
ORDER BY checked_at;

----------------------------------------------------------------------
-- 3. Monthly snapshots via generate_series
----------------------------------------------------------------------
.print ''
.print '── AAPL NYSE price at the start of each month ──'
SELECT
    month.ts::DATE AS month_start,
    sp.valid_from::DATE AS price_date,
    sp.price
FROM (
    SELECT unnest(generate_series(
        '2024-01-01'::TIMESTAMP,
        '2024-12-01'::TIMESTAMP,
        INTERVAL '1 month'
    )) AS ts
) month
LEFT JOIN (
    SELECT * FROM stock_prices
    WHERE ticker = 'AAPL' AND exchange = 'NYSE'
) sp
ON sp.valid_from <= month.ts
QUALIFY ROW_NUMBER() OVER (PARTITION BY month.ts ORDER BY sp.valid_from DESC) = 1
ORDER BY month_start;

----------------------------------------------------------------------
-- 4. Combining AS OF with ASOF JOIN (both features coexist)
----------------------------------------------------------------------
CREATE TABLE orders (
    order_id   INTEGER   NOT NULL,
    valid_from TIMESTAMP NOT NULL,
    status     VARCHAR,
    amount     DECIMAL(10,2),
    PRIMARY KEY (order_id, valid_from)
);

INSERT INTO orders VALUES
    (1, '2024-01-10', 'pending',   100.00),
    (1, '2024-01-12', 'shipped',   100.00),
    (1, '2024-01-15', 'delivered', 100.00),
    (2, '2024-01-20', 'pending',   250.00),
    (2, '2024-01-25', 'cancelled',   0.00),
    (3, '2024-02-01', 'pending',   175.00),
    (3, '2024-02-05', 'shipped',   175.00);

CREATE TABLE events (
    event_ts TIMESTAMP,
    label    VARCHAR
);

INSERT INTO events VALUES
    ('2024-01-11', 'check_1'),
    ('2024-01-14', 'check_2'),
    ('2024-01-22', 'check_3'),
    ('2024-02-03', 'check_4');

.print ''
.print '── Order statuses at each check event (ASOF JOIN) ──'
SELECT
    e.label,
    e.event_ts::DATE AS checked,
    o.order_id,
    o.status,
    o.amount
FROM events e
ASOF JOIN orders o ON e.event_ts >= o.valid_from
ORDER BY e.event_ts, o.order_id;

.print ''
.print '── Order snapshot on Jan 13 (AS OF SELECT) ──'
.print '   Order 1 is shipped, order 2 not yet placed, order 3 not yet placed'
SELECT * FROM orders AT(ASOF => '2024-01-13'::TIMESTAMP) ORDER BY order_id;

.print ''
.print '── Order snapshot on Jan 26 ──'
.print '   Order 1 delivered, order 2 cancelled, order 3 not yet placed'
SELECT * FROM orders AT(ASOF => '2024-01-26'::TIMESTAMP) ORDER BY order_id;

.print ''
.print '── Revenue at three points in time ──'
SELECT '2024-01-13' AS snapshot, sum(amount) AS revenue FROM orders AT(ASOF => '2024-01-13'::TIMESTAMP)
UNION ALL
SELECT '2024-01-26', sum(amount) FROM orders AT(ASOF => '2024-01-26'::TIMESTAMP)
UNION ALL
SELECT '2024-02-10', sum(amount) FROM orders AT(ASOF => '2024-02-10'::TIMESTAMP)
ORDER BY snapshot;

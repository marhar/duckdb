-- AS OF SELECT: Basic Demo
-- Run: ./build/release/duckdb < demo_asof_basic.sql

CREATE TABLE employees (
    name       VARCHAR   NOT NULL,
    valid_from DATE      NOT NULL,
    title      VARCHAR,
    salary     INTEGER,
    PRIMARY KEY (name, valid_from)
);

INSERT INTO employees VALUES
    ('Alice', '2023-01-01', 'Engineer',        100000),
    ('Alice', '2023-07-01', 'Senior Engineer',  120000),
    ('Alice', '2024-03-01', 'Staff Engineer',   150000),
    ('Bob',   '2023-03-01', 'Analyst',           80000),
    ('Bob',   '2024-01-01', 'Senior Analyst',    95000),
    ('Carol', '2024-06-01', 'Designer',          90000),
    ('Dave',  '2023-01-01', 'Manager',          130000),
    ('Dave',  '2024-02-01', NULL,                    0);

.print '── All rows ──'
SELECT * FROM employees ORDER BY name, valid_from;

.print ''
.print '── Company roster on 2023-06-01 ──'
.print '   Alice and Dave started in Jan, Bob is 3 months in'
SELECT * FROM employees AT(ASOF => '2023-06-01'::TIMESTAMP) ORDER BY name;

.print ''
.print '── Company roster on 2024-01-15 ──'
.print '   Dave still here, Carol not yet hired'
SELECT * FROM employees AT(ASOF => '2024-01-15'::TIMESTAMP) ORDER BY name;

.print ''
.print '── Company roster on 2024-06-15 ──'
.print '   Dave retired in Feb, Carol just started'
SELECT * FROM employees AT(ASOF => '2024-06-15'::TIMESTAMP) ORDER BY name;

.print ''
.print '── Active employees on 2024-06-15 (filter out retired) ──'
SELECT * FROM employees AT(ASOF => '2024-06-15'::TIMESTAMP) WHERE title IS NOT NULL ORDER BY name;

.print ''
.print '── Total payroll over time ──'
SELECT '2023-06-01' AS snapshot,
       count(*) FILTER (WHERE title IS NOT NULL) AS headcount,
       sum(salary) AS payroll
FROM employees AT(ASOF => '2023-06-01'::TIMESTAMP)
UNION ALL
SELECT '2024-01-15', count(*) FILTER (WHERE title IS NOT NULL), sum(salary)
FROM employees AT(ASOF => '2024-01-15'::TIMESTAMP)
UNION ALL
SELECT '2024-06-15', count(*) FILTER (WHERE title IS NOT NULL), sum(salary)
FROM employees AT(ASOF => '2024-06-15'::TIMESTAMP)
ORDER BY snapshot;

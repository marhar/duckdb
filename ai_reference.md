# AS-OF Queries in DuckDB: AI Reference

This file is a concise reference for AI coding assistants generating
point-in-time / AS-OF queries in DuckDB.

## Data Model

Time-versioned data uses the step-function model:

```sql
CREATE TABLE data (
    key        VARCHAR   NOT NULL,  -- entity identifier
    valid_from TIMESTAMP NOT NULL,  -- when this value became effective
    value      ...                  -- the payload (any type or multiple columns)
);
-- (key, valid_from) is unique
```

Each row means: "this value is effective from `valid_from` until the
next row's `valid_from` for the same key." Do NOT store a `valid_until`
column — it is derivable and creates maintenance burden.

## The Operation

```
value = as_of(table, key, timestamp)
```

Given a key and timestamp, return the most recent row where
`valid_from <= timestamp`. All methods below implement this.

## Method Summary

### 1. arg_max — best for single-point lookups

```sql
SELECT arg_max(value, valid_from) AS value
FROM data
WHERE key = 'X' AND valid_from <= '2024-06-15'::TIMESTAMP;
```

- Returns only the value, not the full row.
- Fastest single-point method (5ms at 100M rows).
- For the full row, use QUALIFY instead.

### 2. QUALIFY — best general-purpose method

```sql
SELECT key, valid_from, value
FROM data
WHERE key = 'X' AND valid_from <= '2024-06-15'::TIMESTAMP
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY key ORDER BY valid_from DESC
) = 1;
```

- Returns the full row.
- DuckDB rewrites the ROW_NUMBER into a GROUP BY + max() internally.
- 7ms single-point, 13.9 µs/query batch at 100M rows.
- Works for "latest value" by dropping the `valid_from <=` filter.
- Works for "all keys at one time" by dropping the `key =` filter.

### 3. ASOF JOIN — best for batch lookups (cleanest SQL)

```sql
SELECT q.key, q.query_ts, d.valid_from, d.value
FROM queries q
ASOF JOIN data d
       ON q.key = d.key
      AND q.query_ts >= d.valid_from;
```

- For each row in `queries`, finds the nearest preceding row in `data`.
- Produces exactly one output row per left-side row (no fanout).
- Uses a merge join (sorts both sides). Slower than hash-join methods
  but scales predictably and produces no intermediate blowup.
- 29.9 µs/query batch, 87ms single-point at 100M rows.

### 4. Time stitching — fastest batch query (requires pre-computation)

Stitch `valid_until` onto the table:

```sql
CREATE TABLE data_stitched AS
SELECT *,
    LEAD(valid_from) OVER (PARTITION BY key ORDER BY valid_from) AS valid_until
FROM data;
```

Then query with a range predicate:

```sql
SELECT * FROM data_stitched
WHERE key = 'X'
  AND valid_from <= '2024-06-15'::TIMESTAMP
  AND (valid_until > '2024-06-15'::TIMESTAMP OR valid_until IS NULL);
```

- 6.3 µs/query batch at 100M rows (fastest query).
- Materialization cost: 2.6s at 100M rows (one-time).
- Must re-stitch when source data changes.
- NULL valid_until means "currently effective" (last row per key).

### 5. Correlated subquery — avoid at scale

```sql
SELECT * FROM data d
WHERE d.key = 'X'
  AND d.valid_from = (
      SELECT MAX(valid_from) FROM data
      WHERE key = 'X' AND valid_from <= '2024-06-15'::TIMESTAMP
  );
```

- Portable to all SQL databases.
- Fine for single-point (8ms at 100M).
- Degrades superlinearly in batch: 315 µs/query at 100M (50x slower
  than the best method). Avoid for batch workloads.

## Common Patterns

### Latest value (current)

```sql
-- One key
SELECT arg_max(value, valid_from) AS value
FROM data WHERE key = 'X';

-- All keys
SELECT key, valid_from, value FROM data
QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY valid_from DESC) = 1;
```

### Snapshot: all keys at one time

```sql
SELECT key, valid_from, value FROM data
WHERE valid_from <= '2024-06-15'::TIMESTAMP
QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY valid_from DESC) = 1;
```

### Batch: many (key, time) pairs

```sql
-- Inline
SELECT q.key, q.query_ts, d.value
FROM (VALUES
    ('A', '2024-03-15'::TIMESTAMP),
    ('B', '2024-06-01'::TIMESTAMP)
) AS q(key, query_ts)
ASOF JOIN data d ON q.key = d.key AND q.query_ts >= d.valid_from;

-- From a table
SELECT q.key, q.query_ts, d.value
FROM queries q
ASOF JOIN data d ON q.key = d.key AND q.query_ts >= d.valid_from;
```

### Reusable macro

```sql
CREATE MACRO as_of_lookup(tbl, lookup_key, lookup_ts) AS TABLE
    SELECT key, valid_from, value
    FROM query_table(tbl)
    WHERE key = lookup_key AND valid_from <= lookup_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY valid_from DESC) = 1;

-- Usage:
SELECT * FROM as_of_lookup('data', 'X', '2024-06-15'::TIMESTAMP);
```

### Derive valid_until as a view (time stitching without materialization)

```sql
CREATE VIEW data_ranges AS
SELECT *,
    LEAD(valid_from) OVER (PARTITION BY key ORDER BY valid_from) AS valid_until
FROM data;
```

### Resample at regular intervals

```sql
SELECT g.grid_ts, d.value
FROM (SELECT unnest(generate_series(
    '2024-01-01'::TIMESTAMP,
    '2024-12-31'::TIMESTAMP,
    INTERVAL '1 day'
)) AS grid_ts) g
ASOF LEFT JOIN data d
    ON 'X' = d.key AND g.grid_ts >= d.valid_from;
```

## Decision Rules

| Situation | Use |
|-----------|-----|
| Single key, single time | `arg_max` or `QUALIFY` |
| Current/latest value | `arg_max` (no time filter) |
| All keys at one time | `QUALIFY` with `PARTITION BY key` |
| Batch: many lookups | `ASOF JOIN` |
| Batch, max performance | Materialized time-stitched table |
| Must be portable SQL | Correlated subquery (but not for batch) |

## Syntax Gotchas

1. **ASOF JOIN inequality needs a column reference, not a literal.**
   This fails:
   ```sql
   ASOF JOIN data d ON 'X' = d.key AND '2024-06-15' >= d.valid_from
   ```
   The timestamp side must be a column from the left table. Wrap the
   literal in a subquery:
   ```sql
   FROM (SELECT 'X' AS key, '2024-06-15'::TIMESTAMP AS ts) q
   ASOF JOIN data d ON q.key = d.key AND q.ts >= d.valid_from
   ```

2. **ASOF JOIN (inner) drops rows with no match.** Use `ASOF LEFT JOIN`
   to keep them with NULLs.

3. **QUALIFY is DuckDB-specific.** For portable SQL, use a subquery
   with ROW_NUMBER or the correlated MAX approach.

4. **`range()` returns BIGINT.** When adding to DATE, cast explicitly:
   `'2024-01-01'::DATE + r::INTEGER` (DATE + BIGINT is not supported).

5. **Don't store valid_until.** It's derivable via `LEAD()` and creates
   update anomalies. If needed, use a view or materialize + re-stitch
   on data changes.

## Performance at 100M Rows (10K keys x 10K rows/key)

Batch (100K queries):

| Method | Per query | Throughput |
|--------|-----------|------------|
| Materialized stitched | 6.3 µs | ~160K qps |
| arg_max | 13.2 µs | ~75K qps |
| QUALIFY | 13.9 µs | ~72K qps |
| View-based stitched | 20.8 µs | ~48K qps |
| ASOF JOIN | 29.9 µs | ~33K qps |
| Correlated subquery | 315 µs | ~3K qps |

Single-point:

| Method | Latency |
|--------|---------|
| arg_max | 5 ms |
| QUALIFY | 7 ms |
| Correlated subquery | 8 ms |
| Materialized stitched | 18 ms |
| View-based stitched | 58 ms |
| ASOF JOIN | 87 ms |

Rankings differ between batch and single-point because:
- Batch is dominated by join strategy (hash vs. merge) and
  intermediate row fanout.
- Single-point is dominated by filter pushdown — methods that narrow
  to one key before scanning are fastest; ASOF JOIN sorts the entire
  table.

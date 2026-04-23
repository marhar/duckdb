# Design: AS OF Clause for SELECT

## Overview

Add temporal point-in-time query syntax to table references in SELECT, enabling
queries on time-versioned tables.

Two syntax forms are supported:

```sql
-- PEG parser (clean syntax)
SELECT * FROM data ASOF('2024-06-15'::TIMESTAMP);

-- Yacc parser (via AT clause)
SELECT * FROM data AT(ASOF => '2024-06-15'::TIMESTAMP);
```

Returns the state of `data` as it would have appeared at that timestamp — one row per
entity, the most recent version where `valid_from <= timestamp`.

## Data Model

Tables use the step-function model:

```sql
CREATE TABLE data (
    key        VARCHAR   NOT NULL,
    valid_from TIMESTAMP NOT NULL,
    value      INTEGER,
    PRIMARY KEY (key, valid_from)
);
```

- `(key, valid_from)` is unique
- Each row is effective from `valid_from` until the next row's `valid_from` for the same key
- No `valid_until` column needed (it's derivable)

## Semantics

The AS OF query is equivalent to:

```sql
SELECT * FROM data
WHERE valid_from <= <ts>
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY <entity_keys> ORDER BY valid_from DESC
) = 1;
```

Where:
- `valid_from` is identified by column name convention
- `entity_keys` = primary key columns minus `valid_from`
- Primary key MUST include `valid_from`

### Entity Key Derivation

| Primary Key | Entity Key (PARTITION BY) | Behavior |
|---|---|---|
| `(id, valid_from)` | `id` | One entity dimension |
| `(ticker, exchange, valid_from)` | `(ticker, exchange)` | Composite entity |
| `(valid_from)` | *(empty)* | Single-entity table, returns at most 1 row |

## Syntax

```
-- PEG parser: ASOF(expr)
FROM <table> ASOF(<expr>)
FROM <table> <alias> ASOF(<expr>)
FROM <table> AS <alias> ASOF(<expr>)

-- Yacc parser: AT(ASOF => expr)
FROM <table> AT(ASOF => <expr>)
FROM <table> <alias> AT(ASOF => <expr>)
FROM <table> AS <alias> AT(ASOF => <expr>)
```

`<expr>` is any constant expression that evaluates to a timestamp.

### Why Two Syntaxes?

The `ASOF` keyword is already used for `ASOF JOIN`. In the yacc (LALR) parser, adding
`ASOF(expr)` to `opt_at_clause` creates a shift/reduce conflict with the ASOF JOIN
production — the parser greedily consumes ASOF for the at-clause and breaks
`FROM t1 ASOF JOIN t2`. The PEG parser handles this via backtracking.

Both syntaxes produce the same internal `AtClause(unit="ASOF", expr)` and share the
same binder rewrite logic.

### Relationship to Existing Syntax

- **AT clause** (`table AT (TIMESTAMP => expr)`) — catalog-level time travel (Iceberg,
  DuckLake). Unchanged. AS OF is a different feature operating on user-managed temporal data.
- **ASOF JOIN** (`t1 ASOF JOIN t2 ON ...`) — unchanged. Zero grammar conflicts.

## Implementation

### Parser (PEG)

Extended `AtClause` rule in `extension/autocomplete/include/inlined_grammar.gram`:
```
AtClause <- AtTimeTravelClause / AsOfClause
AtTimeTravelClause <- 'AT' Parens(AtSpecifier)
AsOfClause <- 'ASOF' Parens(Expression)
```

Added `TransformAsOfClause` and `TransformAtTimeTravelClause` to PEG transformer.

### Parser (Yacc)

Added `ASOF` as an `at_unit` in `select.y`:
```yacc
at_unit: TIMESTAMP | VERSION_P | ASOF
```

This allows `AT(ASOF => expr)` with zero grammar conflicts.

### Binder

In `Binder::Bind(BaseTableRef&)`, when AT clause has unit `"ASOF"`:

1. Look up the table (catalog entry, not time-travel)
2. Validate: base table, has `valid_from`, has PK including `valid_from`
3. Build a `SubqueryRef` with the QUALIFY rewrite
4. Bind the subquery

### Error Cases

- No `valid_from` column → `"AS OF requires a 'valid_from' column"`
- No primary key → `"AS OF requires a primary key"`
- `valid_from` not in PK → `"'valid_from' must be part of the primary key"`
- Used on a view → `"AS OF can only be used with base tables"` (v1)

## Future Extensions

- **Two-column model**: `valid_from` + `valid_until` — simpler range filter, no PK needed
- **Column name configuration**: allow specifying which column is the temporal column
- **View support**: propagate AS OF through view definitions
- **AS OF on joins**: `FROM a AT(ASOF => t1) JOIN b AT(ASOF => t2)` with different timestamps

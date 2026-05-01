#!/bin/bash

TMP_SECRETS_DIR=$(mktemp -d)
trap "rm -rf $TMP_SECRETS_DIR" 0

DUCKDB=./build/release/duckdb
TINY=gs://marhar-scratch/tiny.parquet

cat <<. | $DUCKDB 2>&1 | sed -e s/$GCS_ACCESS_KEY/redacted/g -e s/$GCS_ACCESS_SECRET/redacted/g
.echo on
SET secret_directory='$TMP_SECRETS_DIR';
.print ================================================================================================================== NO SECRETS
FROM duckdb_secrets();
SELECT * FROM '$TINY';

.print ================================================================================================================== HMAC
CREATE SECRET s1 (
  TYPE GCS,
  KEY_ID '$GCS_ACCESS_KEY',
  SECRET '$GCS_ACCESS_SECRET'
);
FROM duckdb_secrets();
SELECT * FROM '$TINY';

.print ================================================================================================================== credential chain
DROP SECRET s1;
CREATE SECRET s1 (
  TYPE gcs,
  PROVIDER credential_chain
);
FROM duckdb_secrets();
SELECT * FROM '$TINY';
.

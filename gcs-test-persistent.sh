#!/bin/bash

TMP_SECRETS_DIR=$(mktemp -d)
trap "rm -rf $TMP_SECRETS_DIR" 0

DUCKDB=./build/release/duckdb
TINY=gs://marhar-scratch/tiny.parquet

cat <<. | $DUCKDB 2>&1 | sed -e s/$GCS_ACCESS_KEY/redacted/g -e s/$GCS_ACCESS_SECRET/redacted/g
.echo on
SET secret_directory='$TMP_SECRETS_DIR';
.print ================================================================================================================== persistent credential chain
CREATE SECRET s1 (
  TYPE gcs,
  PROVIDER credential_chain
);
.

cat <<. | $DUCKDB 2>&1 | sed -e s/$GCS_ACCESS_KEY/redacted/g -e s/$GCS_ACCESS_SECRET/redacted/g
.print ================================================================================================================== read persistent credential chain
FROM duckdb_secrets();
SELECT * FROM '$TINY';
.

# New DuckDB Feature: `credential_chain` Authentication for GCS

## Goal

Eliminate the HMAC interop-key requirement for `gs://` access. Let users
authenticate to GCS via Google Application Default Credentials (ADC):

```sql
CREATE OR REPLACE SECRET gcs_secret (
    TYPE gcs,
    PROVIDER credential_chain
);

SELECT * FROM 'gs://my-bucket/data.parquet';
```

## Implementation Status

| Component | Status | Notes |
|---|---|---|
| Registration redirect (`extension_entries.hpp:1212`: aws → httpfs) | ✅ done | committed on `gcs-auth` |
| Provider registration in httpfs (`gcs/credential_chain`) | ✅ done | spike + Phase 1 |
| Source 2: gcloud user credentials | ✅ done | refresh-token exchange against `oauth2.googleapis.com` |
| Source 4: GCE/GKE/Cloud Run/Cloud Functions metadata server | ✅ done | 2s timeout; verified by code inspection only (no GCE host) |
| Chain fallthrough + helpful failure messages | ✅ done | tested |
| `refresh_info` wiring → 401 triggers re-fetch | ✅ done | persistent secrets survive token expiry across sessions |
| Source 1: `GOOGLE_APPLICATION_CREDENTIALS` (SA JSON key + JWT RS256) | ❌ deferred | Phase 2; needs OpenSSL JWT signing |
| Source 3: Workload Identity Federation | ❌ deferred | Phase 3; most complex |
| Service account impersonation modifier | ❌ deferred | Phase 3 |
| Production-quality JSON parsing | ✅ done | uses `StringUtil::ParseJSONMap` (yyjson under the hood) via DuckDB core's public API; required-field validation throws on missing/empty values |
| Proactive expiry refresh (T-60s, no 401 round-trip) | ❌ deferred | quality-of-life; current code waits for 401 |
| Mid-stream 401 during a single long file read | ❌ deferred | edge case; would need different hook than `S3FileHandle::Initialize` |

All implemented work lives on branch `gcs-credential-chain` in this fork.
Patches against `duckdb-httpfs@7e86e7a` live in
`.github/patches/extensions/httpfs/`.

## Background

Today, GCS access in DuckDB goes through the S3-compatible interop endpoint:
the `httpfs` extension signs requests with **AWS SigV4** using HMAC keys
(`KEY_ID`, `SECRET`) generated in the GCP console. This forces every user to
provision long-lived HMAC keys tied to a service account — friction that ADC
was specifically designed to eliminate.

A `gcs/credential_chain` provider entry already exists, but it points at the
**`aws` extension** (`src/include/duckdb/main/extension_entries.hpp:1212`),
meaning it walks the AWS credential chain — useless for GCS. This proposal
implements a real Google ADC chain.

## Scope of Change

| Component | Repo | Change |
|---|---|---|
| Secret provider registration | this fork (`duckdb`) | Re-route `gcs/credential_chain` from `aws` → `httpfs` |
| GCS secret function | `duckdb/duckdb-httpfs` | New `CreateGCSSecretFromCredentialChain` |
| ADC token acquisition | `duckdb/duckdb-httpfs` | New `GoogleCredentialChain` class |
| GCS request signing | `duckdb/duckdb-httpfs` | Add Bearer-token auth path alongside existing SigV4 path |
| Tests | both | Unit + integration |
| Docs | `duckdb/duckdb-web` | New section under GCS auth |

The bulk of the work lives in the **httpfs** extension. This fork only owns
the one-line registration redirect.

## Authentication Methods Covered

The provider implements Google's standard ADC resolution order. Each source
is tried in turn; the first one that yields a usable token wins.

1. **`GOOGLE_APPLICATION_CREDENTIALS` env var** — path to a service-account
   JSON key file. RSA-sign a JWT assertion, exchange at
   `https://oauth2.googleapis.com/token` for an access token.
2. **gcloud user credentials** —
   `~/.config/gcloud/application_default_credentials.json`, written by
   `gcloud auth application-default login`. Refresh-token flow against the
   same token endpoint. The dev-laptop case.
3. **Workload Identity Federation** — external-account JSON config; exchanges
   an OIDC/AWS/Azure token via STS for a GCP access token. Increasingly the
   recommended path for cross-cloud workloads.
4. **GCE / GKE / Cloud Run / Cloud Functions metadata server** — fetch token
   from `http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`
   with the `Metadata-Flavor: Google` header. Zero-config production case.
5. **Impersonated service account** *(optional refinement)* — if
   `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` is set (or via a named parameter),
   exchange the base credential for a token on the target SA via the IAM
   Credentials API.

Optional named parameters on the secret:

```sql
CREATE SECRET gcs_secret (
    TYPE gcs,
    PROVIDER credential_chain,
    CHAIN 'env;gcloud;metadata',           -- restrict resolution order
    IMPERSONATE_SERVICE_ACCOUNT 'sa@proj.iam.gserviceaccount.com',
    QUOTA_PROJECT 'billing-project-id',    -- requester-pays / cross-project
    SCOPE 'gs://bucket/prefix/'
);
```

## Implementation Plan

### Phase 1 — Registration redirect (this fork)

**File:** `src/include/duckdb/main/extension_entries.hpp:1212`

```diff
-    {"gcs/credential_chain", "aws"},
+    {"gcs/credential_chain", "httpfs"},
```

Also regenerate any derived files (`scripts/generate_extensions_function.py`).
This must land alongside the httpfs change to avoid a window where the
provider points at httpfs but httpfs doesn't yet register it.

### Phase 2 — Token acquisition library (httpfs)

New module `extension/httpfs/gcs/google_credentials.{hpp,cpp}`:

- `class GoogleCredentialChain` — resolves an `AccessToken { string token; timestamp_t expires_at; }`
- One subclass per source: `EnvJsonCredentials`, `GcloudUserCredentials`,
  `MetadataServerCredentials`, `WorkloadIdentityCredentials`
- JWT RS256 signing via OpenSSL (already a transitive dep — confirm in
  httpfs `vcpkg.json`)
- JSON parsing via `StringUtil::ParseJSONMap` (DuckDB core's public yyjson-backed API)
- HTTPS via the existing httpfs HTTP client
- Thread-safe token cache with refresh-before-expiry (60s skew)

### Phase 3 — GCS filesystem Bearer-token path (httpfs)

Today GCS reuses `S3FileSystem` with a GCS endpoint. Add a branch:

- If the resolved secret is `credential_chain` provider → set
  `Authorization: Bearer <token>` header, **do not** SigV4-sign
- If the resolved secret is `config` provider with HMAC keys → existing
  SigV4 path (unchanged, backwards compatible)
- Refresh token on 401 with retry-once semantics

### Phase 4 — Secret function (httpfs)

Register in the GCS secret module:

```cpp
CreateSecretFunction credential_chain_fn = {
    "gcs", "credential_chain", CreateGCSSecretFromCredentialChain
};
credential_chain_fn.named_parameters["chain"]      = LogicalType::VARCHAR;
credential_chain_fn.named_parameters["impersonate_service_account"] = LogicalType::VARCHAR;
credential_chain_fn.named_parameters["quota_project"] = LogicalType::VARCHAR;
ExtensionUtil::RegisterFunction(instance, credential_chain_fn);
```

The function stores the *configuration* (chain order, impersonation target)
in a `KeyValueSecret`, not a captured token. Token resolution happens lazily
inside the filesystem handler so refresh just works.

### Phase 5 — Tests

Unit tests (httpfs):
- Mock each ADC source independently; assert correct precedence
- JWT signing produces a parseable, correctly-signed assertion
- Token cache returns same token until near expiry, refreshes after
- Malformed credential JSON yields a clear error

Integration tests (gated behind `GCS_INTEGRATION_TESTS=1` + a real bucket):
- `GOOGLE_APPLICATION_CREDENTIALS=...` pointing at a test SA key
- `gcloud auth application-default login` user creds
- GCE metadata path (only runs on GCE; skipped otherwise)
- Long-running query (>1h) survives token expiry

### Phase 6 — Docs

Update `duckdb/duckdb-web` GCS authentication page: list the four+ ADC
sources, the named parameters, a "which should I pick?" decision tree, and
a warning that HMAC keys remain supported for back-compat but ADC is
recommended.

## Build and Test

### Prerequisites

- macOS or Linux with `cmake`, `ninja` or `make`, Python 3
- For testing source 2 (gcloud user creds): `gcloud` CLI installed and
  `gcloud auth application-default login` already run
- For end-to-end testing: a GCS bucket you can read

### First build

Clones the pinned `duckdb-httpfs` commit, applies our patch, and links it
in. ~15 minutes on a cold cache, much faster on warm builds.

```bash
BUILD_HTTPFS=1 make -j8
```

Resulting artifacts:

- `build/release/duckdb` — the CLI
- `build/release/extension/httpfs/httpfs.duckdb_extension` — loadable extension
- `build/release/_deps/httpfs_extension_fc-src/` — synced httpfs source (where
  edits go if you want to modify the patch)

### Rebuilding after changing the patch

```bash
FORCE_APPLY_PATCHES=1 BUILD_HTTPFS=1 make -j8
```

`FORCE_APPLY_PATCHES=1` resets the synced httpfs working tree and reapplies
all patches. Without it, the build refuses to run if it detects local edits
in the synced directory (a safety check).

### Editing the patch

Source edits go in the synced httpfs directory, then are diff-captured into
the patch file:

```bash
# 1. Edit
$EDITOR build/release/_deps/httpfs_extension_fc-src/src/create_secret_functions.cpp

# 2. Capture the diff into our patch
(cd build/release/_deps/httpfs_extension_fc-src && \
 git diff src/create_secret_functions.cpp src/include/create_secret_functions.hpp) \
 > .github/patches/extensions/httpfs/0003-gcs-credential-chain.patch

# 3. Rebuild
FORCE_APPLY_PATCHES=1 BUILD_HTTPFS=1 make -j8
```

### Smoke test — source 2 (gcloud user creds)

Replace `YOUR-BUCKET/some.parquet` with something you can read:

```bash
./build/release/duckdb -c "
LOAD httpfs;
CREATE SECRET adc (TYPE gcs, PROVIDER credential_chain, SCOPE 'gs://YOUR-BUCKET/');
SELECT name FROM which_secret('gs://YOUR-BUCKET/some.parquet', 'gcs');
SELECT count(*) FROM 'gs://YOUR-BUCKET/some.parquet';
"
```

The `SCOPE` and `which_secret()` check matter if you also have a persistent
HMAC secret stored — the narrower scope wins, guaranteeing the credential_chain
secret is the one used. Without the narrow scope, two same-scope secrets exist
and the persistent HMAC could be picked silently — you'd think
credential_chain works when the test is actually using HMAC.

### Failure-mode test (no source available)

```bash
HOME=/nonexistent ./build/release/duckdb -c "
LOAD httpfs;
CREATE SECRET t (TYPE gcs, PROVIDER credential_chain);
"
```

Expected: clean `IOException` in under one second naming both attempted
sources, with instructions to run `gcloud auth application-default login` or
move to a GCE host. No 30-second hang on the metadata server timeout (DNS
fails fast on non-GCE hosts; the 2s timeout is only the safety net).

### Persistent secret round-trip

Confirms the refresh metadata survives serialization to disk:

```bash
SECRETS_DIR=$(mktemp -d)

# Session A: create the persistent secret
./build/release/duckdb -c "
LOAD httpfs;
SET secret_directory = '$SECRETS_DIR';
CREATE PERSISTENT SECRET adc_p (TYPE gcs, PROVIDER credential_chain);
"

# Session B: read it back, confirm refresh fields
./build/release/duckdb -c "
LOAD httpfs;
SET secret_directory = '$SECRETS_DIR';
SELECT secret_string FROM duckdb_secrets() WHERE name='adc_p';
"

rm -rf "$SECRETS_DIR"
```

The session-B `secret_string` should contain `refresh=auto` and
`refresh_info={'_provider': credential_chain}`. That's what enables transparent
token refresh on a 401 in tomorrow's session.

### What can't be tested locally

- **Source 4 (GCE metadata server)** — only fires on GCE/GKE/Cloud
  Run/Cloud Functions. On other hosts the source is silently skipped.
- **Token refresh on 401** — would require waiting >1h for the OAuth
  access token to expire, or revoking it manually with `gcloud auth revoke`.
- **Sources 1 (SA JSON key + JWT) and 3 (WIF)** — not implemented.

## Risks & Open Questions

- **OpenSSL dep in httpfs** — confirm `vcpkg.json` already pulls it in; if
  not, that's a non-trivial build-system change.
- **Workload Identity Federation** — the spec is large. Reasonable to ship
  Phase 2 with sources 1, 2, 4 and add WIF in a follow-up.
- **`CHAIN` parameter syntax** — match AWS extension's existing convention
  (`'env;config;sts'`-style) for consistency rather than inventing new.
- **Naming** — `credential_chain` matches `s3`/`r2`/`azure`. An `adc`
  alias is tempting but probably noise.
- **Upstream coordination** — this needs an RFC/issue against
  `duckdb/duckdb-httpfs` before code lands; the registration redirect in
  this fork is meaningless until httpfs ships.

## Out of Scope

- Changing the default GCS auth method (HMAC remains supported).
- Service-account key rotation tooling.
- A general OAuth2 framework for other providers (keep this GCS-specific
  for now).

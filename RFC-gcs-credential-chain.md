# RFC: `PROVIDER credential_chain` for GCS via Google Application Default Credentials

**Status:** Draft, seeking feedback

**Affected repos:** `duckdb/duckdb-httpfs` (primary), `duckdb/duckdb` (one-line registration table change)

**Author:** Mark Harrison (marhar@gmail.com), with Claude Code assistance

## Summary

Implement a `gcs/credential_chain` provider that authenticates to GCS using
Google Application Default Credentials (ADC), eliminating the need for HMAC
interop keys.

## Motivation

GCS users currently have one option in DuckDB:

```sql
CREATE SECRET (TYPE gcs, KEY_ID '...', SECRET '...');
```

These are HMAC keys, which require generating and managing the key pair.
Google recomments using ADC over HMAC and has incorporated ADC support
into most Cloud systems.

The proposed change brings GCS to parity with other clouds that implement
authentication via credential chains.

```sql
CREATE SECRET (TYPE gcs, PROVIDER credential_chain);
```

## Current state

In `duckdb/duckdb`, `src/include/duckdb/main/extension_entries.hpp`:

```cpp
{"s3/credential_chain",  "aws"},
{"gcs/credential_chain", "aws"},   // ← walks AWS chain; not what GCS users want
{"r2/credential_chain",  "aws"},
```

In `duckdb-httpfs`, `src/s3fs.cpp` already has a complete OAuth2 Bearer-token
auth path for GCS — six call sites that send `Authorization: Bearer <token>`
when `auth_params.oauth2_bearer_token` is non-empty (lines 562, 586, 607, 632,
659, 678). The existing `gcs/config` provider already accepts a `bearer_token`
named parameter that flows into this field.

What's missing: a provider that obtains a bearer token from ADC.

## Proposed API

```sql
-- Minimal — uses standard ADC resolution order:
CREATE SECRET gcs_secret (
    TYPE gcs,
    PROVIDER credential_chain
);

-- With optional refinements:
CREATE SECRET gcs_secret (
    TYPE gcs,
    PROVIDER credential_chain,
    CHAIN 'env;gcloud;metadata',                              -- restrict order
    SCOPE 'gs://my-bucket/',                                  -- standard
    IMPERSONATE_SERVICE_ACCOUNT 'sa@proj.iam.gserviceaccount.com',
    QUOTA_PROJECT 'billing-project-id'                        -- requester-pays
);
```

Behavior follows Google's published ADC semantics; named parameters are
additive refinements that map cleanly to existing `gcloud` flags.

## Authentication chain

In ADC resolution order (first source that yields a usable token wins):

| # | Source | Notes |
|---|---|---|
| 1 | `GOOGLE_APPLICATION_CREDENTIALS` env var → service-account JSON key | Requires JWT RS256 signing |
| 2 | `~/.config/gcloud/application_default_credentials.json` (gcloud user creds) | Refresh-token flow, no JWT needed |
| 3 | Workload Identity Federation external-account JSON | STS exchange; complex |
| 4 | GCE/GKE/Cloud Run/Cloud Functions metadata server | `Metadata-Flavor: Google` header |
| 5 | Impersonated service account *(optional refinement, not a chain step)* | `IMPERSONATE_SERVICE_ACCOUNT` parameter |

A reasonable phased rollout:

- **Phase 1**: sources (2) and (4). Covers laptop dev + most production cases.
  No JWT signing, minimal new code.
- **Phase 2**: source (1). Adds JWT RS256 via OpenSSL (already a transitive
  dep of httpfs).
- **Phase 3**: source (3) Workload Identity Federation, plus impersonation.

Sources (2) and (4) cover the majority of use cases; it might be reasonable
to start with these and see if there is demand before implementing (1), (3), and (5).

## Token lifecycle

OAuth2 access tokens from Google expire in ~1h. The provider must:

- Fetch lazily (on filesystem use, not at `CREATE SECRET` time) so that
  long-lived persistent secrets remain valid across token rotations.
- Cache the token (with ~60s skew before expiry) to avoid re-fetching on
  every request.
- Refresh on 401 with retry-once.

The existing httpfs `refresh` machinery (`CreateS3SecretFunctions::TryRefreshS3Secret`)
is a starting point but was designed for HMAC rotation, not OAuth refresh — may
warrant a small extension or parallel mechanism.

## Backwards Compatibility

The current HMAC scheme should remain fully supported. HMAC credentials will
not be affected by this change.

## Where should this code live?

Two viable homes; this RFC requests guidance from maintainers.

**Option A — inside `duckdb-httpfs`.**
- Pros: GCS filesystem already lives here. Bearer-token plumbing already
  exists. OpenSSL and curl are already linked. No new extension repo to
  maintain. Symmetric with `huggingface/credential_chain` which is already
  in httpfs.
- Cons: Adds Google-specific OAuth code to a generic-sounding extension.

**Option B — new `gcp` extension parallel to `aws`.**
- Pros: Symmetric with the `aws` extension. Keeps Google-specific OAuth code
  out of httpfs. Easier to evolve independently (e.g. add other GCP services
  later — Pub/Sub, BigQuery).
- Cons: New repo, new release artifacts, new vcpkg manifest, new CI. The
  `aws` extension exists primarily to wrap the AWS SDK; we don't need a
  Google Cloud SDK (HTTP + JSON suffice), so the parallel is weaker than it
  appears.

**Recommendation:** Option A. The `huggingface/credential_chain` precedent
inside httpfs makes this the lowest-friction path. If a `gcp` extension is
ever needed for non-filesystem services, the credential code can move then.

Either way, the registration table in `duckdb/duckdb` needs to change from:

```cpp
{"gcs/credential_chain", "aws"},
```

to point at whichever extension owns the new provider.

## Spike evidence

A working proof of concept exists locally (≈150-line patch on top of httpfs
`7e86e7a`):

- `gcs/credential_chain` provider registered in `CreateS3SecretFunctions::RegisterCreateSecretFunction`
- Reads `~/.config/gcloud/application_default_credentials.json`
- POSTs refresh-token exchange to `https://oauth2.googleapis.com/token`
  via `HTTPUtil`
- Returns access token in `secret_map["bearer_token"]`
- Existing GCS filesystem code in `s3fs.cpp` picks it up and authenticates
  successfully against a real `gs://` bucket (verified with a 42k-row
  parquet read)

The spike intentionally cuts corners (crude string-based JSON parsing
instead of yyjson, single ADC source, no token caching) — its only purpose
was to prove feasibility before opening this RFC. A production
implementation would use yyjson, walk the full chain, and cache tokens.

For convenience of code verification, Print lines with `[GCS-ADC]` prefix were added to the spike.
These of course should be removed before final submission.

Spike artifacts:
- https://github.com/marhar/duckdb/pull/1
- https://github.com/marhar/duckdb-httpfs/pull/1
- test cases and results for persistent and transient secrets.

```
gcs-test-persistent.out
gcs-test-persistent.sh
gcs-test.out
gcs-test.sh
```

## Open questions for maintainers

1. **Home for the code** — Option A (httpfs) or Option B (new `gcp`
   extension)?
2. **JWT/RS256 signing** — acceptable to add OpenSSL JWT signing inside
   httpfs for source (1)? OpenSSL is already linked, but the symbolic
   weight of "OAuth code in the HTTP filesystem extension" deserves a
   sanity check.
3. **`CHAIN` parameter syntax** — match the existing AWS extension
   convention (`'env;config;sts'`) or is there a preferred form?
4. **Token caching strategy** — extend the existing `refresh` mechanism, or
   add a parallel OAuth-specific cache?

## Out of scope

- Changing the default GCS auth method. HMAC `gcs/config` continues to
  work as-is.
- A general-purpose OAuth2 framework. This is GCS-specific.
- Removing or deprecating the existing `bearer_token` named parameter on
  `gcs/config` (which lets users supply a token they obtained externally).

## Asks

1. Maintainer feedback on the two open design questions above (code home,
   JWT in httpfs).
2. Indication of whether a phased PR (Phase 1 first) would be welcome, or
   whether you'd prefer a single comprehensive PR.
3. Once aligned, I'll open a PR against the agreed-upon repo.


## Test Run Output
```
================================================================================================================== credential chain
[GCS-ADC] CREATE SECRET (TYPE gcs, PROVIDER credential_chain) name='s1' input_options=0
[GCS-ADC]   no SCOPE provided; defaulting to ['gcs://', 'gs://']
[GCS-ADC] trying source: gcloud user credentials
[GCS-ADC]   source 2 (gcloud): checking /Users/markharrison/.config/gcloud/application_default_credentials.json
[GCS-ADC]   source 2 (gcloud): read 385 bytes from credentials file
[GCS-ADC]   source 2 (gcloud): parsed client_id (72 chars), client_secret (24 chars), refresh_token (103 chars) — values not printed
[GCS-ADC]   source 2 (gcloud): POST https://oauth2.googleapis.com/token (form body 268 bytes)
[GCS-ADC]   source 2 (gcloud): token endpoint responded status=200 body=1456 bytes
[GCS-ADC]   source 2 (gcloud): extracted access_token (256 chars) — value not printed
[GCS-ADC]   → SUCCESS from gcloud user credentials (token 256 chars)
[GCS-ADC] storing bearer_token in KeyValueSecret (256 chars)
[GCS-ADC] set refresh=auto + refresh_info STRUCT (1 fields) — 401 hook will refire this function on token expiry
[GCS-ADC] CREATE SECRET complete
CREATE SECRET s1 (
  TYPE gcs,
  PROVIDER credential_chain
);
FROM duckdb_secrets();
┌─────────┬─────────┬──────────────────┬────────────┬─────────┬─────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  name   │  type   │     provider     │ persistent │ storage │        scope        │                                                                          secret_string                                                                          │
│ varchar │ varchar │     varchar      │  boolean   │ varchar │      varchar[]      │                                                                             varchar                                                                             │
├─────────┼─────────┼──────────────────┼────────────┼─────────┼─────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ s1      │ gcs     │ credential_chain │ false      │ memory  │ ['gcs://', 'gs://'] │ name=s1;type=gcs;provider=credential_chain;serializable=true;scope=gcs://,gs://;bearer_token=redacted;refresh=auto;refresh_info={'_provider': credential_chain} │
└─────────┴─────────┴──────────────────┴────────────┴─────────┴─────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
SELECT * FROM 'gs://mybucket/tiny.parquet';
┌────────┬──────────────────────────────┐
│ Answer │            status            │
│ int32  │           varchar            │
├────────┼──────────────────────────────┤
│     42 │ Every cloud tells a story... │
└────────┴──────────────────────────────┘
```

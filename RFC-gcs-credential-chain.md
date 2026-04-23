# RFC: `PROVIDER credential_chain` for GCS via Google Application Default Credentials

**Status:** Draft, seeking feedback
**Affected repos:** `duckdb/duckdb-httpfs` (primary), `duckdb/duckdb` (one-line registration table change)
**Author:** Mark Harrison

## Summary

Implement a real `gcs/credential_chain` provider that authenticates to GCS using
Google Application Default Credentials (ADC), eliminating the need for HMAC
interop keys. Today this provider name is registered to the `aws` extension,
which walks the *AWS* credential chain — not useful for GCS users.

## Motivation

GCS users currently have one option in DuckDB:

```sql
CREATE SECRET (TYPE gcs, KEY_ID '...', SECRET '...');
```

These are HMAC interop keys, which require:

1. Generating an HMAC key pair tied to a GCP service account through the
   console or `gsutil`
2. Pasting long-lived secrets into a DuckDB secret
3. Manual rotation

Google has spent the better part of a decade pushing users *away* from HMAC
keys toward ADC, and most production GCP environments (GCE/GKE/Cloud Run/Cloud
Functions) come with ADC pre-configured. Forcing DuckDB users back to HMAC is
friction that other DuckDB cloud integrations (S3, R2, Azure) have already
eliminated via `credential_chain`.

The proposed change brings GCS to parity:

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

What's missing: a provider that *obtains* a bearer token from ADC.

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

Spike artifacts available on request.

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
5. **Phase 1 scope** — is "gcloud user creds + metadata server" enough for
   an initial PR, with SA keys and WIF as follow-ups? Or should the first
   PR cover the full chain?
6. **Backwards compatibility** — HMAC `gcs/config` remains supported and
   unchanged, correct? (The RFC assumes yes.)

## Out of scope

- Changing the default GCS auth method. HMAC `gcs/config` continues to
  work, unchanged.
- A general-purpose OAuth2 framework. This is GCS-specific.
- Service-account key rotation tooling.
- Removing or deprecating the existing `bearer_token` named parameter on
  `gcs/config` (which lets users supply a token they obtained externally).

## Asks

1. Maintainer feedback on the two open design questions above (code home,
   JWT in httpfs).
2. Indication of whether a phased PR (Phase 1 first) would be welcome, or
   whether you'd prefer a single comprehensive PR.
3. Once aligned, I'll open a PR against the agreed-upon repo.

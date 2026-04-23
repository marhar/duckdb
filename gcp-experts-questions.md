# GCS Authentication for DuckDB — Cloud Experts Discussion

**Context:** DuckDB currently authenticates to GCS via HMAC interop keys (long-lived
secrets generated in the GCP console). We've implemented Phase 1 of an ADC-based
alternative covering sources 2 and 4 below, plus 401-driven token refresh for
persistent secrets. Looking for input from local cloud experts on remaining
sources and whether anything below conflicts with our security policies.

## Authentication sources for the ADC chain

| # | Source | Where it lives | Typical use | Credential lifetime | Spike status |
|---|---|---|---|---|---|
| 1 | **Service account JSON key** | `GOOGLE_APPLICATION_CREDENTIALS` env var → path to JSON file | CI/CD systems, on-prem servers without metadata access, third-party tools | **Long-lived** private key (until rotated) → exchanged for 1h access token via JWT RS256 | ❌ not implemented (needs OpenSSL JWT signing) |
| 2 | **gcloud user credentials** | `~/.config/gcloud/application_default_credentials.json` after `gcloud auth application-default login` | Developer laptops | Long-lived refresh token → 1h access token via OAuth refresh flow | ✅ **shipped (Phase 1)** |
| 3 | **Workload Identity Federation** | External-account JSON pointing at OIDC/AWS/Azure identity | Cross-cloud workloads (e.g. EKS pod accessing GCS), federated CI (GitHub Actions OIDC) | No long-lived GCP secret at rest; external token → STS exchange → 1h GCP token | ❌ not implemented (most complex) |
| 4 | **GCE metadata server** | `http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token` | GCE VMs, GKE pods, Cloud Run, Cloud Functions, Cloud Build | No credential at rest — token issued on demand by the platform's attached SA | ✅ **shipped (Phase 1)** — verified by code inspection only (no GCE host) |
| 5 | **Service account impersonation** *(modifier, not a chain step)* | `IMPERSONATE_SERVICE_ACCOUNT=sa@proj.iam` env var or named param | Privilege escalation patterns, cross-project access | Base credential exchanged for target SA token via IAM Credentials API | ❌ not implemented |

## Resolution order

ADC tries 1 → 2 → 3 → 4. First source that yields a token wins. Source 5 is a
wrapper applied to whichever base credential resolved.

## Questions for the experts

1. **Which sources do our internal GCP environments actually use?**
   Likely #4 in prod, #2 on laptops — but worth confirming. If anyone uses
   #3 for federated workflows, that may bump its priority.

2. **Any policy reasons to *not* support a source?**
   Some orgs ban service-account JSON keys outright in favor of Workload
   Identity Federation — if so, source #1 might be deprioritized or
   excluded.

3. **Token caching policy.** *(partially answered by current implementation)*
   Tokens last ~1h. We took a middle path: tokens are written to disk only
   when the user creates a `PERSISTENT SECRET` (which DuckDB serializes to
   `~/.duckdb/stored_secrets/`), and the secret carries `refresh=auto` +
   `refresh_info` so the existing httpfs hook re-derives a fresh token on
   401. Net effect: a persistent secret created last week still works
   today, automatically, without re-running `CREATE SECRET`. **Open
   question:** any policy concerns with access tokens (not refresh tokens
   or SA keys) hitting disk under the user's `~/.duckdb/` directory?
   Alternative is process-memory-only, but that means re-fetching from
   gcloud/metadata on every session start.

   *Not yet implemented:* proactive refresh at T-60s (current code waits
   for a 401 before refreshing) and mid-stream 401 handling during a
   single long file read. Both are quality-of-life follow-ups.

4. **Quota project / requester-pays.**
   For cross-project access, which credential model are users on
   (impersonation vs WIF vs explicit `QUOTA_PROJECT` header)?

5. **Phasing recommendation.** *(Phase 1 already implemented)*
   Sources 2 and 4 are now shipped on the `gcs-credential-chain` branch
   plus persistent-secret refresh via 401 retry. Does that cover your
   expected users in our orgs, or do we need to prioritize source 1
   (SA JSON keys) or source 3 (WIF) next?

## Suggested framing for the conversation

> "DuckDB has working HMAC-key auth for GCS today. We've shipped Phase 1
> of an ADC alternative — sources 2 and 4 above, plus persistent-secret
> refresh on 401. Two things to validate: do those two sources cover your
> users (or do we need to prioritize SA JSON keys / WIF next), and is
> there anything in our caching approach that conflicts with cloud
> security policy?"

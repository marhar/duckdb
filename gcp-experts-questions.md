# GCS Authentication for DuckDB — Cloud Experts Discussion

**Context:** DuckDB currently authenticates to GCS via HMAC interop keys (long-lived
secrets generated in the GCP console). We've spiked a working ADC-based
implementation and want to scope what to ship first. Looking for input from
local cloud experts on which auth sources matter for our environments and
whether anything below conflicts with our security policies.

## Authentication sources for the ADC chain

| # | Source | Where it lives | Typical use | Credential lifetime | Spike status |
|---|---|---|---|---|---|
| 1 | **Service account JSON key** | `GOOGLE_APPLICATION_CREDENTIALS` env var → path to JSON file | CI/CD systems, on-prem servers without metadata access, third-party tools | **Long-lived** private key (until rotated) → exchanged for 1h access token via JWT RS256 | ❌ not implemented (needs OpenSSL JWT signing) |
| 2 | **gcloud user credentials** | `~/.config/gcloud/application_default_credentials.json` after `gcloud auth application-default login` | Developer laptops | Long-lived refresh token → 1h access token via OAuth refresh flow | ✅ **working in spike** |
| 3 | **Workload Identity Federation** | External-account JSON pointing at OIDC/AWS/Azure identity | Cross-cloud workloads (e.g. EKS pod accessing GCS), federated CI (GitHub Actions OIDC) | No long-lived GCP secret at rest; external token → STS exchange → 1h GCP token | ❌ not implemented (most complex) |
| 4 | **GCE metadata server** | `http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token` | GCE VMs, GKE pods, Cloud Run, Cloud Functions, Cloud Build | No credential at rest — token issued on demand by the platform's attached SA | ❌ not implemented (simple, ~30 lines) |
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

3. **Token caching policy.**
   Tokens last ~1h. Acceptable to cache in process memory only, or do we
   want disk-cached tokens for inter-session reuse? DuckDB sessions are
   typically short-lived, so process-only is probably fine, but checking.

4. **Quota project / requester-pays.**
   For cross-project access, which credential model are users on
   (impersonation vs WIF vs explicit `QUOTA_PROJECT` header)?

5. **Phasing recommendation.**
   If we ship sources 2 and 4 first (Phase 1: laptop dev + GCE/GKE prod),
   does that cover ~90% of expected users in our orgs? Or is that missing
   something critical?

## Suggested framing for the conversation

> "DuckDB has working HMAC-key auth for GCS today. We've spiked a working
> OAuth/ADC implementation (source #2 above) and want to scope what to ship
> first. Which of these sources matter for our environments, and is there
> anything in the above that conflicts with our cloud security policies?"

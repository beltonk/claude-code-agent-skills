# Secret Scanner Patterns

Regex patterns for detecting secrets before memory content enters shared/team storage. Run these against any text before persisting it outside the current session.

## Usage

Scan each line of memory content against all patterns below. If any pattern matches, **reject the memory entry** and warn the user. Return only the rule ID, never the matched text — the scanner itself must not become a leak vector.

## Patterns

| ID | Service | Pattern |
|----|---------|---------|
| 1 | AWS Access Key | `AKIA[0-9A-Z]{16}` |
| 2 | AWS Secret Key | `(?i)aws_secret_access_key\s*[=:]\s*[A-Za-z0-9/+=]{40}` |
| 3 | AWS Session Token | `(?i)aws_session_token\s*[=:]\s*[A-Za-z0-9/+=]{100,}` |
| 4 | GCP Service Account | `"type"\s*:\s*"service_account"` |
| 5 | GCP API Key | `AIza[0-9A-Za-z_-]{35}` |
| 6 | Azure Storage Key | `(?i)AccountKey\s*=\s*[A-Za-z0-9+/=]{88}` |
| 7 | Azure Connection String | `(?i)DefaultEndpointsProtocol=https;AccountName=` |
| 8 | GitHub PAT (classic) | `ghp_[0-9a-zA-Z]{36}` |
| 9 | GitHub PAT (fine-grained) | `github_pat_[0-9a-zA-Z_]{82}` |
| 10 | GitHub App Token | `ghu_[0-9a-zA-Z]{36}` |
| 11 | GitHub OAuth Token | `gho_[0-9a-zA-Z]{36}` |
| 12 | GitHub Refresh Token | `ghr_[0-9a-zA-Z]{36}` |
| 13 | GitLab PAT | `glpat-[0-9a-zA-Z_-]{20,}` |
| 14 | GitLab Pipeline Token | `glpt-[0-9a-zA-Z_-]{20,}` |
| 15 | Slack Bot Token | `xoxb-[0-9]{10,}-[0-9a-zA-Z]{24,}` |
| 16 | Slack User Token | `xoxp-[0-9]{10,}-[0-9]{10,}-[0-9a-zA-Z]{24,}` |
| 17 | Slack App Token | `xapp-[0-9]-[A-Z0-9]{10,}-[0-9]{13}-[0-9a-f]{64}` |
| 18 | Stripe Secret Key | `sk_live_[0-9a-zA-Z]{24,}` |
| 19 | Stripe Restricted Key | `rk_live_[0-9a-zA-Z]{24,}` |
| 20 | Twilio API Key | `SK[0-9a-fA-F]{32}` |
| 21 | SendGrid API Key | `SG\.[0-9a-zA-Z_-]{22}\.[0-9a-zA-Z_-]{43}` |
| 22 | NPM Token | `npm_[0-9a-zA-Z]{36}` |
| 23 | PyPI Token | `pypi-[0-9a-zA-Z_-]{100,}` |
| 24 | OpenAI API Key | `sk-[0-9a-zA-Z]{20}T3BlbkFJ[0-9a-zA-Z]{20}` |
| 25 | Anthropic API Key | `sk-ant-[0-9a-zA-Z_-]{90,}` |
| 26 | HuggingFace Token | `hf_[0-9a-zA-Z]{34,}` |
| 27 | DigitalOcean Token | `dop_v1_[0-9a-f]{64}` |
| 28 | Databricks Token | `dapi[0-9a-f]{32}` |
| 29 | Hashicorp Vault Token | `hvs\.[0-9a-zA-Z]{24,}` |
| 30 | Pulumi Access Token | `pul-[0-9a-f]{40}` |
| 31 | Postman API Key | `PMAK-[0-9a-f]{24}-[0-9a-f]{34}` |
| 32 | Grafana API Key | `eyJrIjoi[0-9a-zA-Z+/=]{40,}` |
| 33 | Sentry Auth Token | `sntrys_[0-9a-zA-Z_-]{60,}` |
| 34 | Shopify Access Token | `shpat_[0-9a-fA-F]{32}` |
| 35 | Private Key (PEM) | `-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----` |
| 36 | Generic High-Entropy Secret | `(?i)(password|secret|token|api_key|apikey)\s*[=:]\s*['"][^\s'"]{20,}['"]` |

## Integration notes

- Scan at the **write boundary** — before content is saved, not when it's read.
- If running as a shell script, `grep -E` with these patterns works for basic scanning. For production use, compile them into a single regex engine pass.
- Pattern 36 (generic) has higher false-positive rates. Consider it advisory.
- Keep matched content out of logs, error messages, and telemetry. Return `{ rule_id: N, matched: true }`, not the matched text.

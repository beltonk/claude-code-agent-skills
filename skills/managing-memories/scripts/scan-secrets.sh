#!/usr/bin/env bash
# Secret scanner for memory content.
# Scans stdin or files for credential patterns before persisting to shared memory.
# Returns exit code 1 if secrets found, 0 if clean.
# Outputs only rule IDs — never the matched text.
#
# Usage:
#   echo "content to scan" | ./scan-secrets.sh
#   ./scan-secrets.sh file1.md file2.md
#   ./scan-secrets.sh memory-directory/
#
# Compatible with bash 3.2+ (macOS default) and bash 4+.

set -euo pipefail

FOUND=0

RULES='
01|AWS_ACCESS_KEY|AKIA[0-9A-Z]{16}
02|AWS_SECRET_KEY|aws_secret_access_key[[:space:]]*[=:][[:space:]]*[A-Za-z0-9/+=]{40}
03|AWS_SESSION_TOKEN|aws_session_token[[:space:]]*[=:][[:space:]]*[A-Za-z0-9/+=]{100,}
04|GCP_SERVICE_ACCOUNT|"type"[[:space:]]*:[[:space:]]*"service_account"
05|GCP_API_KEY|AIza[0-9A-Za-z_-]{35}
06|AZURE_STORAGE_KEY|AccountKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{88}
07|AZURE_CONN_STRING|DefaultEndpointsProtocol=https;AccountName=
08|GITHUB_PAT_CLASSIC|ghp_[0-9a-zA-Z]{36}
09|GITHUB_PAT_FINE|github_pat_[0-9a-zA-Z_]{82}
10|GITHUB_APP_TOKEN|ghu_[0-9a-zA-Z]{36}
11|GITHUB_OAUTH|gho_[0-9a-zA-Z]{36}
12|GITHUB_REFRESH|ghr_[0-9a-zA-Z]{36}
13|GITLAB_PAT|glpat-[0-9a-zA-Z_-]{20,}
14|GITLAB_PIPELINE|glpt-[0-9a-zA-Z_-]{20,}
15|SLACK_BOT|xoxb-[0-9]{10,}-[0-9a-zA-Z]{24,}
16|SLACK_USER|xoxp-[0-9]{10,}-[0-9]{10,}-[0-9a-zA-Z]{24,}
17|SLACK_APP|xapp-[0-9]-[A-Z0-9]{10,}-[0-9]{13}-[0-9a-f]{64}
18|STRIPE_SECRET|sk_live_[0-9a-zA-Z]{24,}
19|STRIPE_RESTRICTED|rk_live_[0-9a-zA-Z]{24,}
20|TWILIO_API_KEY|SK[0-9a-fA-F]{32}
21|SENDGRID|SG\.[0-9a-zA-Z_-]{22}\.[0-9a-zA-Z_-]{43}
22|NPM_TOKEN|npm_[0-9a-zA-Z]{36}
23|PYPI_TOKEN|pypi-[0-9a-zA-Z_-]{100,}
24|OPENAI_KEY|sk-[0-9a-zA-Z]{20}T3BlbkFJ[0-9a-zA-Z]{20}
25|ANTHROPIC_KEY|sk-ant-[0-9a-zA-Z_-]{90,}
26|HF_TOKEN|hf_[0-9a-zA-Z]{34,}
27|DIGITALOCEAN|dop_v1_[0-9a-f]{64}
28|DATABRICKS|dapi[0-9a-f]{32}
29|VAULT_TOKEN|hvs\.[0-9a-zA-Z]{24,}
30|PULUMI|pul-[0-9a-f]{40}
31|POSTMAN|PMAK-[0-9a-f]{24}-[0-9a-f]{34}
32|GRAFANA|eyJrIjoi[0-9a-zA-Z+/=]{40,}
33|SENTRY|sntrys_[0-9a-zA-Z_-]{60,}
34|SHOPIFY|shpat_[0-9a-fA-F]{32}
35|PRIVATE_KEY|BEGIN.*PRIVATE KEY
36|GENERIC_SECRET|(password|secret|token|api_key|apikey)[[:space:]]*[=:][[:space:]]*["][^[:space:]"]{20,}["]
'

scan_content() {
  local content="$1"
  local source="${2:-stdin}"

  echo "$RULES" | while IFS='|' read -r id name pattern; do
    [ -z "$id" ] && continue
    id=$(echo "$id" | tr -d ' ')
    if echo "$content" | grep -qEi -e "$pattern" 2>/dev/null; then
      if [ "$source" = "stdin" ]; then
        echo "MATCH: rule=$id ($name)"
      else
        echo "MATCH: rule=$id ($name) file=$source"
      fi
      touch "${TMPDIR:-/tmp}/.secret_scanner_found_$$"
    fi
  done
}

cleanup() {
  rm -f "${TMPDIR:-/tmp}/.secret_scanner_found_$$"
}
trap cleanup EXIT

if [ $# -eq 0 ]; then
  content=$(cat)
  scan_content "$content"
else
  for target in "$@"; do
    if [ -d "$target" ]; then
      find "$target" -type f -name '*.md' -print0 | while IFS= read -r -d '' file; do
        content=$(cat "$file")
        if [ -n "$content" ]; then
          scan_content "$content" "$(basename "$file")"
        fi
      done
    elif [ -f "$target" ]; then
      content=$(cat "$target")
      scan_content "$content" "$(basename "$target")"
    else
      echo "WARNING: $target not found" >&2
    fi
  done
fi

if [ -f "${TMPDIR:-/tmp}/.secret_scanner_found_$$" ]; then
  echo "---"
  echo "SECRET(S) DETECTED. Do not persist this content to shared memory."
  exit 1
else
  echo "CLEAN: No secrets detected."
  exit 0
fi

#!/usr/bin/env bash
# Export all Dependabot alerts for a GitHub org to JSON Lines (one alert per line).
#
# Usage:
#   ./export_dependabot_alerts.sh <org> [output.jsonl]
#
# Example:
#   ./export_dependabot_alerts.sh Newton-Research-Inc dependabot_alerts.jsonl
set -euo pipefail

ORG="${1:?Usage: $0 <org> [output.jsonl]}"
OUT="${2:-/dev/stdout}"

gh api --paginate "/orgs/${ORG}/dependabot/alerts" | jq -c '.[]' > "$OUT"

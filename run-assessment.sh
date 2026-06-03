#!/usr/bin/env bash
#
# run-assessment.sh
# Sends the collected CONTEXT.md bundle + the upstream prompt.md to the
# Anthropic API and prints the upgrade risk assessment.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   ./run-assessment.sh <CONTEXT.md> <SOURCE_VERSION> <TARGET_VERSION> [prompt.md]
#
# If prompt.md is not provided locally it is fetched from the repo.
# Requires: curl, jq.

set -euo pipefail

CTX_FILE="${1:?Usage: run-assessment.sh CONTEXT.md SOURCE TARGET [prompt.md]}"
SRC="${2:?missing SOURCE_VERSION}"
TGT="${3:?missing TARGET_VERSION}"
PROMPT_FILE="${4:-}"
MODEL="${ANTHROPIC_MODEL:-claude-opus-4-8}"

command -v jq   >/dev/null || { echo "need jq" >&2; exit 1; }
command -v curl >/dev/null || { echo "need curl" >&2; exit 1; }
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"

# fetch prompt.md if not supplied
if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  PROMPT_FILE="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/syedammarsuhail/AI-Kubernetes-Upgrades/main/prompt.md -o "$PROMPT_FILE"
fi

# substitute versions into the prompt placeholders
PROMPT="$(sed -e "s|<SOURCE_VERSION>|$SRC|g" -e "s|<TARGET_VERSION>|$TGT|g" "$PROMPT_FILE")"

# Assemble the full user message into a temp file (avoids "Argument list too
# long": jq --rawfile reads from disk instead of argv).
MSG_FILE="$(mktemp)"
BODY_FILE=""
trap 'rm -f "$MSG_FILE" "$BODY_FILE" 2>/dev/null' EXIT
{
  printf '%s\n\n' "$PROMPT"
  printf '============================================================\n'
  printf 'COLLECTED CLUSTER EVIDENCE (read-only snapshot)\n'
  printf '============================================================\n\n'
  cat "$CTX_FILE"
} > "$MSG_FILE"

BYTES="$(wc -c < "$MSG_FILE")"
echo "Model: $MODEL  |  source=$SRC target=$TGT  |  message=$BYTES bytes" >&2

# Context-window guard. ~4 bytes/token; 200k-token window. Refuse > ~700KB
# so we don't waste a call on a request the API will reject.
if [ "$BYTES" -gt 700000 ]; then
  echo "ERROR: message is ${BYTES} bytes (~$((BYTES/4)) tokens) — too large for the model's context window." >&2
  echo "Re-run the collector (it now keeps big -o yaml dumps in raw/ only), or trim CONTEXT.md." >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
jq -n --arg model "$MODEL" --rawfile content "$MSG_FILE" '{
  model: $model,
  max_tokens: 8000,
  messages: [ { role: "user", content: $content } ]
}' > "$BODY_FILE"

curl -fsS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d @"$BODY_FILE" \
| jq -r '.content[] | select(.type=="text") | .text'

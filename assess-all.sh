#!/usr/bin/env bash
#
# assess-all.sh
# Run the upgrade readiness collector + assessment across MANY clusters.
#
# For each cluster it:
#   1. collects in lite mode, auto-shrinking until the bundle fits the
#      model's context window (tries embed caps 120 -> 60 -> 30 -> 15)
#   2. autodetects the source version from the bundle
#   3. picks the target = next minor (source+1) unless you pass -t
#   4. runs the assessment and saves a per-cluster report
#   5. prints a summary table at the end
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   ./assess-all.sh                         # ALL contexts in your kubeconfig
#   ./assess-all.sh ctxA ctxB ctxC          # only these contexts
#   ./assess-all.sh -t 1.33 ctxA ctxB       # force the same target for all
#   ./assess-all.sh -C ctxA ctxB            # collect only, skip the API call
#   ./assess-all.sh -o reports ctxA         # custom output dir
#
# Needs: kubectl, jq, curl, and the two sibling scripts
#        (k8s-upgrade-assess.sh, run-assessment.sh) in the same folder.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COLLECT="$HERE/k8s-upgrade-assess.sh"
ASSESS="$HERE/run-assessment.sh"
SIZE_LIMIT=680000          # stay just under the runner's 700000 guard
CAPS="120 60 30 15"        # embed-line caps to try, largest first

FORCE_TARGET=""
COLLECT_ONLY=0
OUTROOT="./assessments-$(date +%Y%m%d-%H%M%S)"

while getopts ":t:o:Ch" opt; do
  case "$opt" in
    t) FORCE_TARGET="$OPTARG" ;;
    o) OUTROOT="$OPTARG" ;;
    C) COLLECT_ONLY=1 ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    \?) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
    :) echo "Option -$OPTARG needs an argument" >&2; exit 1 ;;
  esac
done
shift $((OPTIND-1))

for f in "$COLLECT" "$ASSESS"; do
  [ -x "$f" ] || chmod +x "$f" 2>/dev/null
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
if [ "$COLLECT_ONLY" = 0 ]; then
  command -v jq >/dev/null && command -v curl >/dev/null || { echo "ERROR: need jq and curl" >&2; exit 1; }
  : "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY (or use -C to collect only)}"
fi

# contexts: from args, else every context in the kubeconfig
if [ "$#" -gt 0 ]; then
  CONTEXTS=("$@")
else
  mapfile -t CONTEXTS < <(kubectl config get-contexts -o name 2>/dev/null)
fi
[ "${#CONTEXTS[@]}" -gt 0 ] || { echo "ERROR: no contexts found" >&2; exit 1; }

mkdir -p "$OUTROOT"
echo "================================================================"
echo " Multi-cluster upgrade assessment"
echo " contexts : ${CONTEXTS[*]}"
echo " output   : $OUTROOT"
echo " mode     : $([ "$COLLECT_ONLY" = 1 ] && echo 'collect only' || echo 'collect + assess')"
echo "================================================================"

# next minor version: 1.32 -> 1.33
next_minor() { awk -F. '{print $1"."($2+1)}' <<<"$1"; }

# summary rows
declare -a SUMMARY

for CTX in "${CONTEXTS[@]}"; do
  SAFE="$(echo "$CTX" | tr -c 'A-Za-z0-9._-' '_')"
  DIR="$OUTROOT/$SAFE"
  mkdir -p "$DIR"
  echo
  echo ">>> [$CTX] checking connectivity ..."
  if ! kubectl --context="$CTX" version >/dev/null 2>&1 \
     && ! kubectl --context="$CTX" cluster-info >/dev/null 2>&1; then
    echo "    UNREACHABLE — skipping"
    SUMMARY+=("$CTX|-|-|-|UNREACHABLE")
    continue
  fi

  # collect, shrinking the embed cap until the bundle fits
  CTXMD=""; BYTES=0; USED_CAP=""
  for cap in $CAPS; do
    echo "    collecting (embed cap=$cap) ..."
    MAX_EMBED_LINES="$cap" "$COLLECT" -k "$CTX" -t "${FORCE_TARGET:-1.0}" -L -o "$DIR/run-$cap" >/dev/null 2>&1
    CTXMD="$DIR/run-$cap/CONTEXT.md"
    if [ -f "$CTXMD" ]; then
      BYTES="$(wc -c < "$CTXMD")"
      echo "    -> $BYTES bytes"
      if [ "$BYTES" -le "$SIZE_LIMIT" ]; then USED_CAP="$cap"; break; fi
    fi
  done

  if [ -z "$USED_CAP" ]; then
    echo "    STILL TOO LARGE even at smallest cap ($BYTES bytes) — collected, not assessed."
    SUMMARY+=("$CTX|?|?|$BYTES|TOO_LARGE")
    continue
  fi

  # source version from the bundle header; target = forced or next minor
  SRC="$(grep -m1 '^SOURCE_VERSION:' "$CTXMD" | awk '{print $2}')"
  [ -z "$SRC" ] || [ "$SRC" = "unknown" ] && SRC="$(kubectl --context="$CTX" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' | sed 's/^v//' | cut -d. -f1,2)"
  TGT="${FORCE_TARGET:-$(next_minor "$SRC")}"

  if [ "$COLLECT_ONLY" = 1 ]; then
    echo "    collected $SRC (cap=$USED_CAP). Skipping assessment (-C)."
    SUMMARY+=("$CTX|$SRC|$TGT|$BYTES|COLLECTED")
    continue
  fi

  REPORT="$DIR/assessment-$SRC-to-$TGT.md"
  echo "    assessing $SRC -> $TGT ..."
  if "$ASSESS" "$CTXMD" "$SRC" "$TGT" > "$REPORT" 2>"$DIR/assess.err"; then
    echo "    report: $REPORT"
    SUMMARY+=("$CTX|$SRC|$TGT|$BYTES|OK")
  else
    echo "    ASSESSMENT FAILED — see $DIR/assess.err"
    head -2 "$DIR/assess.err" | sed 's/^/      /'
    SUMMARY+=("$CTX|$SRC|$TGT|$BYTES|API_FAIL")
  fi
done

echo
echo "================================================================"
echo " SUMMARY"
echo "================================================================"
printf '%-28s %-8s %-8s %-12s %s\n' "CONTEXT" "SOURCE" "TARGET" "BYTES" "STATUS"
for row in "${SUMMARY[@]}"; do
  IFS='|' read -r c s t b st <<<"$row"
  printf '%-28s %-8s %-8s %-12s %s\n' "$c" "$s" "$t" "$b" "$st"
done
echo
echo "All output under: $OUTROOT"
echo "Reports: $OUTROOT/<context>/assessment-<src>-to-<tgt>.md"

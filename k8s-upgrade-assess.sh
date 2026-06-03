#!/usr/bin/env bash
#
# k8s-upgrade-assess.sh
# Read-only Kubernetes upgrade-readiness data collector.
# It NEVER modifies the cluster. Every kubectl call is a read
# (version/get/describe/api-resources/top). Output is a folder of raw
# evidence plus a single CONTEXT.md bundle you can paste to an LLM
# together with prompt.md to produce the risk assessment.
#
# Usage:
#   ./k8s-upgrade-assess.sh -t 1.30 [-s 1.27] [-k CONTEXT] [-L] [-o OUTDIR]
#
#   -s  SOURCE_VERSION (e.g. 1.27)         [optional, autodetected if omitted]
#   -t  TARGET_VERSION (e.g. 1.30)         [required for API-removal scan]
#   -k  kubectl context to use             [default: current-context]
#   -L  lite mode (smaller bundle for big clusters / context limits)
#   -o  output directory                   [default: ./k8s-upgrade-<timestamp>]
#   -h  help
#
# Requirements: kubectl, awk, sed. Optional: jq, pluto or kubent
# (much better deprecated/removed-API detection if present).

set -uo pipefail   # NOT -e: we want to continue past individual command failures

# ---------- args ----------
SOURCE_VERSION=""
TARGET_VERSION=""
OUTDIR=""
CONTEXT=""
LITE=0
KUBECTL_BIN="${KUBECTL:-kubectl}"

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }

while getopts ":s:t:o:k:Lh" opt; do
  case "$opt" in
    s) SOURCE_VERSION="$OPTARG" ;;
    t) TARGET_VERSION="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    k) CONTEXT="$OPTARG" ;;
    L) LITE=1 ;;
    h) usage 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
    :) echo "Option -$OPTARG needs an argument" >&2; usage 1 ;;
  esac
done

KC="$KUBECTL_BIN"
[ -n "$CONTEXT" ] && KC="$KUBECTL_BIN --context=$CONTEXT"

command -v "$KUBECTL_BIN" >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_PLUTO=0; command -v pluto >/dev/null 2>&1 && HAVE_PLUTO=1
HAVE_KUBENT=0; command -v kubent >/dev/null 2>&1 && HAVE_KUBENT=1

# connectivity check (read-only)
if ! $KC version >/dev/null 2>&1; then
  if ! $KC cluster-info >/dev/null 2>&1; then
    echo "ERROR: cannot reach cluster. Check your kubeconfig / context." >&2
    exit 1
  fi
fi

TS="$(date +%Y%m%d-%H%M%S)"
[ -z "$OUTDIR" ] && OUTDIR="./k8s-upgrade-$TS"
mkdir -p "$OUTDIR/raw"
RAW="$OUTDIR/raw"
CTX="$OUTDIR/CONTEXT.md"

# Autodetect source version if not given
if [ -z "$SOURCE_VERSION" ]; then
  SOURCE_VERSION="$($KC version -o json 2>/dev/null \
    | { [ "$HAVE_JQ" = 1 ] && jq -r '.serverVersion.gitVersion' || grep -o '"gitVersion":[^,]*' | head -1 | cut -d'"' -f4; } \
    | sed 's/^v//' | cut -d. -f1,2)"
  [ -n "$SOURCE_VERSION" ] && echo "Autodetected SOURCE_VERSION=$SOURCE_VERSION"
fi

echo "================================================================"
echo " Kubernetes upgrade readiness collection (READ-ONLY)"
echo " source : ${SOURCE_VERSION:-unknown}"
echo " target : ${TARGET_VERSION:-not set}"
echo " output : $OUTDIR"
echo " jq:$HAVE_JQ pluto:$HAVE_PLUTO kubent:$HAVE_KUBENT"
echo "================================================================"

# ---------- helpers ----------
section() { echo -e "\n\n---\n\n# $1\n" >> "$CTX"; echo ">> $1"; }
fence()   { echo '```'"${1:-text}" >> "$CTX"; }
endfence(){ echo '```' >> "$CTX"; }

# max lines of any single command's output to embed in CONTEXT.md
# (full output is always kept in raw/). Keeps the LLM bundle small.
MAX_EMBED_LINES="${MAX_EMBED_LINES:-400}"
[ "$LITE" = 1 ] && MAX_EMBED_LINES=120

# run a read-only command, tee raw file, embed (truncated) into CONTEXT.md
run() {
  local label="$1" file="$2"; shift 2
  echo "   - $label"
  echo -e "\n## \`$*\`\n" >> "$CTX"
  fence text
  { "$@"; } >"$RAW/$file" 2>>"$RAW/_errors.log"
  if [ -s "$RAW/$file" ]; then
    local n; n="$(wc -l < "$RAW/$file")"
    if [ "$n" -gt "$MAX_EMBED_LINES" ]; then
      head -n "$MAX_EMBED_LINES" "$RAW/$file" >> "$CTX"
      echo "... [truncated: $n lines total, full output in raw/$file]" >> "$CTX"
    else
      cat "$RAW/$file" >> "$CTX"
    fi
  else
    echo "(no output / not present)" >> "$CTX"
  fi
  endfence
}

# run a read-only command, save to raw/ ONLY (never embedded — used for
# large -o yaml dumps that would blow up the LLM context window)
run_raw() {
  local label="$1" file="$2"; shift 2
  echo "   - $label (raw only)"
  { "$@"; } >"$RAW/$file" 2>>"$RAW/_errors.log"
  echo -e "\n## \`$*\` -> saved to raw/$file (not embedded; too large for context)\n" >> "$CTX"
}

# header of the bundle
cat > "$CTX" <<EOF
# Kubernetes Upgrade Assessment — Collected Cluster Evidence

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
SOURCE_VERSION: ${SOURCE_VERSION:-unknown}
TARGET_VERSION: ${TARGET_VERSION:-NOT SET}

> Read-only snapshot. Feed this file to an LLM together with prompt.md
> to produce the upgrade feasibility / risk assessment.
EOF

# ================= STEP 1: cluster information =================
section "Step 1 - Cluster Information"
run "version"        version.txt        $KC version -o yaml
run "cluster-info"   cluster-info.txt   $KC cluster-info
run "nodes -o wide"  nodes-wide.txt     $KC get nodes -o wide
run_raw "nodes -o yaml"  nodes.yaml      $KC get nodes -o yaml
run "namespaces"     namespaces.txt     $KC get ns
run "api-resources"  api-resources.txt  $KC api-resources
run "apiservices"    apiservices.txt    $KC get apiservices

# ================= STEP 2: workload inventory =================
section "Step 2 - Resource Inventory"
run "all -A"     all.txt       $KC get all -A
run "deploy -A"  deploy.txt    $KC get deploy -A -o wide
run "sts -A"     sts.txt       $KC get sts -A -o wide
run "ds -A"      ds.txt        $KC get ds -A -o wide
run "jobs -A"    jobs.txt      $KC get jobs -A
run "cronjobs -A" cronjobs.txt $KC get cronjobs -A
run "pods restarts" pod-restarts.txt $KC get pods -A \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount'

# ================= STEP 3: CRDs =================
section "Step 3 - CRD Inventory"
run "crd list"  crd-list.txt  $KC get crd
run_raw "crd yaml"  crd.yaml      $KC get crd -o yaml
# concise CRD summary (name / group / kind / versions / storage / strategy)
echo -e "\n## CRD summary\n" >> "$CTX"; fence text
if [ "$HAVE_JQ" = 1 ]; then
  $KC get crd -o json 2>/dev/null | jq -r '
    .items[] |
    "\(.metadata.name)\n  group:    \(.spec.group)\n  kind:     \(.spec.names.kind)\n  versions: \([.spec.versions[].name]|join(","))\n  served:   \([.spec.versions[]|select(.served)|.name]|join(","))\n  storage:  \([.spec.versions[]|select(.storage)|.name]|join(","))\n  convert:  \(.spec.conversion.strategy // "None")"
  ' 2>/dev/null | tee "$RAW/crd-summary.txt" >> "$CTX"
else
  echo "(install jq for a parsed CRD summary; raw crd.yaml captured)" >> "$CTX"
fi
endfence

# ================= STEP 4: controllers / operators =================
section "Step 4 - Controllers & Operators (signature scan)"
# scan all workload container images for well-known operator signatures
$KC get deploy,ds,sts -A -o json 2>/dev/null \
  | { [ "$HAVE_JQ" = 1 ] && jq -r '.items[] | "\(.metadata.namespace)/\(.kind)/\(.metadata.name) \([.spec.template.spec.containers[].image]|join(" "))"' || cat; } \
  > "$RAW/workload-images.txt" 2>/dev/null

PATTERNS='cert-manager|ingress-nginx|external-dns|cluster-autoscaler|metrics-server|prometheus|kube-state-metrics|grafana|argocd|argo-cd|fluxcd|flux|crossplane|istio|pilot|linkerd|gatekeeper|kyverno|velero|karpenter|aws-load-balancer|ebs-csi|efs-csi|cilium|calico|antrea|coredns|kube-proxy|csi-|longhorn|rook|ceph|nfs|metallb|sealed-secrets|vault|cnpg|cloudnative-pg|opentelemetry|fluent'
echo -e "\n## Detected controller/operator signatures\n" >> "$CTX"; fence text
grep -aoiE "$PATTERNS" "$RAW/workload-images.txt" 2>/dev/null | sort | uniq -c | sort -rn \
  | tee "$RAW/detected-operators.txt" >> "$CTX"
[ -s "$RAW/detected-operators.txt" ] || echo "(no well-known operator image signatures matched)" >> "$CTX"
endfence
echo -e "\n## Full workload image list\n" >> "$CTX"; fence text
if [ "$LITE" = 1 ]; then
  echo "(omitted in lite mode — see raw/workload-images.txt; operator signatures above)" >> "$CTX"
else
  head -n "$MAX_EMBED_LINES" "$RAW/workload-images.txt" >> "$CTX"
  [ "$(wc -l < "$RAW/workload-images.txt")" -gt "$MAX_EMBED_LINES" ] && \
    echo "... [truncated; full list in raw/workload-images.txt]" >> "$CTX"
fi
endfence

# ================= STEP 6/7: deprecated & removed API scan =================
section "Step 6/7 - Deprecated & Removed API Scan"

# Best tools first, if installed
if [ "$HAVE_PLUTO" = 1 ]; then
  echo -e "\n## pluto detect-all-in-cluster\n" >> "$CTX"; fence text
  pluto detect-all-in-cluster -t k8s=v"${TARGET_VERSION}.0" 2>/dev/null \
    | tee "$RAW/pluto.txt" >> "$CTX"; endfence
fi
if [ "$HAVE_KUBENT" = 1 ]; then
  echo -e "\n## kubent (kube-no-trouble)\n" >> "$CTX"; fence text
  kubent -t "${TARGET_VERSION}.0" -c=false 2>&1 \
    | tee "$RAW/kubent.txt" >> "$CTX"; endfence
fi

# Built-in fallback scan: look in last-applied-configuration annotations
# (catches Helm / kubectl-apply resources still referencing removed APIs).
# Table: apiVersion regex  ->  "removed-in-version : note"
build_removed_table() {
cat <<'TBL'
extensions/v1beta1|1.16|Deployment/DaemonSet/ReplicaSet/Ingress/NetworkPolicy/PodSecurityPolicy
apps/v1beta1|1.16|Deployment/StatefulSet/ReplicaSet -> apps/v1
apps/v1beta2|1.16|Deployment/DaemonSet/ReplicaSet/StatefulSet -> apps/v1
apiextensions.k8s.io/v1beta1|1.22|CustomResourceDefinition -> v1
apiregistration.k8s.io/v1beta1|1.22|APIService -> v1
admissionregistration.k8s.io/v1beta1|1.22|Validating/MutatingWebhookConfiguration -> v1
rbac.authorization.k8s.io/v1beta1|1.22|Role/RoleBinding/ClusterRole/ClusterRoleBinding -> v1
certificates.k8s.io/v1beta1|1.22|CertificateSigningRequest -> v1
coordination.k8s.io/v1beta1|1.22|Lease -> v1
scheduling.k8s.io/v1beta1|1.22|PriorityClass -> v1
storage.k8s.io/v1beta1|1.22|CSIDriver/CSINode/StorageClass/VolumeAttachment(some) -> v1
networking.k8s.io/v1beta1|1.22|Ingress/IngressClass -> networking.k8s.io/v1
extensions/v1beta1 Ingress|1.22|Ingress -> networking.k8s.io/v1
batch/v1beta1|1.25|CronJob -> batch/v1
discovery.k8s.io/v1beta1|1.25|EndpointSlice -> discovery.k8s.io/v1
events.k8s.io/v1beta1|1.25|Event -> events.k8s.io/v1
autoscaling/v2beta1|1.25|HorizontalPodAutoscaler -> autoscaling/v2
node.k8s.io/v1beta1|1.25|RuntimeClass -> node.k8s.io/v1
policy/v1beta1 PodSecurityPolicy|1.25|PodSecurityPolicy REMOVED (migrate to Pod Security Admission)
policy/v1beta1 PodDisruptionBudget|1.25|PodDisruptionBudget -> policy/v1
autoscaling/v2beta2|1.26|HorizontalPodAutoscaler -> autoscaling/v2
flowcontrol.apiserver.k8s.io/v1beta1|1.26|FlowSchema/PriorityLevelConfiguration -> v1beta3/v1
storage.k8s.io/v1beta1 CSIStorageCapacity|1.27|CSIStorageCapacity -> storage.k8s.io/v1
flowcontrol.apiserver.k8s.io/v1beta2|1.29|FlowSchema/PriorityLevelConfiguration -> v1
flowcontrol.apiserver.k8s.io/v1beta3|1.32|FlowSchema/PriorityLevelConfiguration -> v1
TBL
}

# dump last-applied-configuration across all namespaced + cluster objects
echo -e "\n## Built-in scan of last-applied-configuration annotations\n" >> "$CTX"; fence text
LAC="$RAW/last-applied.txt"
$KC get all,ing,netpol,pdb,hpa,cronjob,crd,csidriver,csinode,storageclass,priorityclass,role,rolebinding,clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration,apiservice -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}{"\n"}{end}' \
  > "$LAC" 2>/dev/null

FOUND=0
while IFS='|' read -r api ver note; do
  [ -z "$api" ] && continue
  base="${api%% *}"  # strip trailing "Kind" qualifier for grep
  hits="$(grep -aF "\"apiVersion\":\"$base\"" "$LAC" 2>/dev/null | cut -f1 | sort -u)"
  if [ -n "$hits" ]; then
    FOUND=1
    sev="HIGH"
    if [ -n "$TARGET_VERSION" ]; then
      # CRITICAL if removal version <= target
      awk -v r="$ver" -v t="$TARGET_VERSION" 'BEGIN{split(r,a,".");split(t,b,"."); exit !(a[1]<b[1]||(a[1]==b[1]&&a[2]<=b[2]))}' && sev="CRITICAL"
    fi
    echo "[$sev] apiVersion=$api  removed-in=v$ver  ($note)"
    while read -r obj; do echo "        -> $obj"; done <<< "$hits"
  fi
done < <(build_removed_table) | tee "$RAW/removed-api-findings.txt" >> "$CTX"
[ "$FOUND" = 0 ] && echo "(no removed/deprecated apiVersions found in last-applied-configuration annotations)" >> "$CTX"
echo >> "$CTX"
echo "NOTE: live objects are re-serialized by the API server to the preferred" >> "$CTX"
echo "version, so this only catches resources with a last-applied annotation" >> "$CTX"
echo "(Helm/kubectl-apply). Install 'pluto' or 'kubent' for authoritative detection." >> "$CTX"
endfence

# ================= STEP 10: admission webhooks =================
section "Step 10 - Admission Webhooks"
run "validating webhooks" vwc.txt $KC get validatingwebhookconfigurations -o wide
run "mutating webhooks"   mwc.txt $KC get mutatingwebhookconfigurations -o wide
run_raw "validating yaml"     vwc.yaml $KC get validatingwebhookconfigurations -o yaml
run_raw "mutating yaml"       mwc.yaml $KC get mutatingwebhookconfigurations -o yaml
# failurePolicy summary (a hard "Fail" policy can block workloads on upgrade)
echo -e "\n## Webhook failurePolicy summary\n" >> "$CTX"; fence text
if [ "$HAVE_JQ" = 1 ]; then
  for k in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    $KC get "$k" -o json 2>/dev/null | jq -r --arg K "$k" '
      .items[] as $c | $c.webhooks[]? |
      "\($K) \($c.metadata.name)/\(.name) failurePolicy=\(.failurePolicy // "Fail(default)") sideEffects=\(.sideEffects // "?")"'
  done | tee "$RAW/webhook-policy.txt" >> "$CTX"
else
  echo "(install jq for failurePolicy summary)" >> "$CTX"
fi
endfence

# ================= STEP 11: networking =================
section "Step 11 - Networking"
run "services -A"     svc.txt    $KC get svc -A -o wide
run "ingress -A"      ing.txt    $KC get ingress -A -o wide
run "ingressclass"    ingc.txt   $KC get ingressclass
run "networkpolicies" netpol.txt $KC get netpol -A
run "coredns"         coredns.txt $KC -n kube-system get deploy,cm -l k8s-app=kube-dns -o wide
run "kube-proxy"      kubeproxy.txt $KC -n kube-system get ds -l k8s-app=kube-proxy -o wide
run "cni pods"        cni.txt    $KC -n kube-system get pods -o wide

# ================= STEP 12: storage =================
section "Step 12 - Storage"
run "storageclasses" sc.txt  $KC get storageclass -o wide
run "csidrivers"     csidrv.txt $KC get csidrivers
run "csinodes"       csinode.txt $KC get csinodes
run "pv"             pv.txt  $KC get pv -o wide
run "pvc -A"         pvc.txt $KC get pvc -A -o wide
run "volumesnapshotclasses" vsc.txt $KC get volumesnapshotclasses

# ================= STEP 13: security =================
section "Step 13 - Security"
run "podsecuritypolicies" psp.txt $KC get psp
run "PSA namespace labels" psa.txt $KC get ns -o custom-columns='NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce,AUDIT:.metadata.labels.pod-security\.kubernetes\.io/audit,WARN:.metadata.labels.pod-security\.kubernetes\.io/warn'
# privileged / hostPath / hostNetwork workloads
echo -e "\n## Privileged / host-namespace / hostPath pods\n" >> "$CTX"; fence text
if [ "$HAVE_JQ" = 1 ]; then
  $KC get pods -A -o json 2>/dev/null | jq -r '
    .items[] | select(
      (.spec.hostNetwork==true) or (.spec.hostPID==true) or (.spec.hostIPC==true) or
      ([.spec.containers[].securityContext.privileged]|any(.==true)) or
      ([.spec.volumes[]?.hostPath]|length>0)
    ) | "\(.metadata.namespace)/\(.metadata.name)  hostNet=\(.spec.hostNetwork // false) hostPID=\(.spec.hostPID // false) hostIPC=\(.spec.hostIPC // false)"' \
    | tee "$RAW/privileged-pods.txt" >> "$CTX"
  [ -s "$RAW/privileged-pods.txt" ] || echo "(none found)" >> "$CTX"
else
  echo "(install jq for privileged-pod detection)" >> "$CTX"
fi
endfence

# ================= STEP 14: runtime =================
section "Step 14 - Node Runtime"
echo -e "\n## Node runtime / OS / kubelet summary\n" >> "$CTX"; fence text
$KC get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,ARCH:.status.nodeInfo.architecture' \
  2>/dev/null | tee "$RAW/node-runtime.txt" >> "$CTX"
endfence

# ================= STEP 15: resource pressure =================
section "Step 15 - Resource Pressure"
run "top nodes" top-nodes.txt $KC top nodes
run "top pods -A" top-pods.txt $KC top pods -A
echo -e "\n(\"kubectl top\" requires metrics-server; empty output means it isn't installed.)" >> "$CTX"

# ================= done =================
echo -e "\n\n---\n\n# Collection complete\n" >> "$CTX"
echo "Raw evidence in: $RAW/" >> "$CTX"
echo
echo "================================================================"
echo " Done."
echo " Bundle : $CTX"
echo " Raw    : $RAW/"
if [ -s "$RAW/removed-api-findings.txt" ]; then
  echo
  echo " !! Potential removed/deprecated API usage detected:"
  sed 's/^/    /' "$RAW/removed-api-findings.txt"
fi
echo
echo " Next: send CONTEXT.md + prompt.md to an LLM, e.g."
echo "   ./run-assessment.sh $CTX <source> <target>"
echo "================================================================"

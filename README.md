# AI-Assisted Kubernetes Upgrade Readiness

Assess whether a Kubernetes cluster is safe to upgrade — **before** you touch it.

This toolkit performs a **read-only** scan of a cluster, bundles the evidence,
and uses an AI model to produce a structured upgrade risk assessment (risk
matrix, readiness score, and a clear "what will break" list). It can run across
a whole fleet in one go, and ships an optional human-in-the-loop remediation
agent that proposes fixes but asks before changing anything.

> **The scripts only analyze.** They never modify the cluster. The actual
> upgrade stays a deliberate, manual `kubeadm` step you perform after reading
> the report.

---

## Workflow

```
Collect  ──▶  Assess  ──▶  Review  ──▶  Remediate & Upgrade  ──┐
(read-only)   (AI report)  (human)     (kubeadm, one minor)    │
   ▲                                                            │
   └──────────────────── re-analyze ───────────────────────────┘
```

---

## Components

| File | Role |
|------|------|
| `k8s-upgrade-assess.sh` | Read-only collector. Scans one cluster, writes `CONTEXT.md`. Supports `-L` (lite) and `-k <context>`. |
| `run-assessment.sh` | Single-cluster runner. Sends one bundle + the prompt to the model, prints the report. |
| `assess-all.sh` | Multi-cluster wrapper. Loops contexts, calls the two scripts, auto-shrinks bundles, one report per cluster. |
| `k8s-agent.py` | Human-in-the-loop remediation agent. Runs read-only checks automatically; **asks before any change**; defaults to dry-run. |

---

## Prerequisites

- `kubectl` access to the target cluster(s)
- `bash` (run with `./script.sh` or `bash script.sh` — **not** `sh`)
- `jq` and `curl`
- An **Anthropic API key** (`console.anthropic.com`; pay-as-you-go, separate from a chat plan)
- Outbound access to `api.anthropic.com`
- *Recommended:* [`pluto`](https://github.com/FairwindsOps/pluto) or
  [`kubent`](https://github.com/doitintl/kube-no-trouble) for authoritative
  removed/deprecated-API detection

---

## Setup

```bash
chmod +x k8s-upgrade-assess.sh run-assessment.sh assess-all.sh

# confirm access
kubectl config get-contexts -o name
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/messages   # 405 = reachable

export ANTHROPIC_API_KEY=sk-ant-...
```

---

## Usage

### Single cluster

```bash
# 1. collect (read-only, lite mode)
./k8s-upgrade-assess.sh -t 1.33 -L -k <context-name>
wc -c ./k8s-upgrade-*/CONTEXT.md        # want < ~700000

# 2. assess (source -> target, single minor hop)
./run-assessment.sh ./k8s-upgrade-<timestamp>/CONTEXT.md 1.32 1.33 | tee report.md
```

### Whole fleet

```bash
./assess-all.sh                     # every context in the kubeconfig
./assess-all.sh prod staging edge   # specific contexts
./assess-all.sh -t 1.33 prod        # force a target
./assess-all.sh -C                  # collect only (no API call)
```

Reports land under `assessments-<timestamp>/<context>/`, with a summary table:

| STATUS | Meaning |
|--------|---------|
| `OK` | Report written |
| `UNREACHABLE` | Could not connect to that context |
| `API_FAIL` | API call errored (see `assess.err`) |
| `TOO_LARGE` | Bundle didn't fit even at the smallest cap |
| `COLLECTED` | Collected only (`-C`); not assessed |

### Remediation agent (optional)

```bash
# plan only (safe, executes nothing)
python3 k8s-agent.py --report report.md --context my-ctx

# execute, approving each change
python3 k8s-agent.py --report report.md --context my-ctx --apply

# auto-approve only low-risk reversible changes
python3 k8s-agent.py --report report.md --context my-ctx --apply --auto-safe
```

---

## Reading the report

Focus on:

1. **Upgrade Decision** — `APPROVED` / `CONDITIONAL` / `NOT RECOMMENDED`
2. **Readiness Score** and **Confidence Score**
3. **"WHAT WILL BREAK"** and the required actions before upgrade

---

## Performing the upgrade (manual)

One minor version at a time, per cluster:

1. Fix the report's blockers (spread CoreDNS, upgrade old add-ons, remove orphaned webhooks, …)
2. **Back up etcd** (critical for single, non-HA control planes)
3. Control plane: `kubeadm upgrade plan` → `kubeadm upgrade apply v1.X.y`
4. Each node: `drain` → upgrade `kubelet`/`kubeadm` → `kubeadm upgrade node` → `uncordon`
5. Re-run the analyzer, then repeat for the next minor

Follow the official guide for your exact versions:
<https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>

---

## Notes & limitations

- **Single-minor hops only** (`1.32 → 1.33`, not `1.32 → 1.35`). Re-run for each step.
- The built-in removed-API scan only catches Helm/`kubectl apply` resources;
  install `pluto`/`kubent` for authoritative detection.
- The report is a **strong first pass, not gospel** — verify against vendor
  compatibility matrices and the official docs before acting.
- `kubectl top` output requires `metrics-server`; empty output just means it
  isn't installed.
- Bundles must fit the model's context window; use `-L` (and `MAX_EMBED_LINES=60`)
  for large clusters.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Illegal option -o pipefail` | You ran it with `sh`. Use `./script.sh` or `bash script.sh`. |
| `jq: Argument list too long` | Use the runner that reads via `--rawfile` (current version). |
| `message too large for context window` | Re-collect with `-L`, and/or `MAX_EMBED_LINES=60`. |
| `Could not resolve host: api.anthropic.com` | Fix DNS/egress, add an `/etc/hosts` entry, or use the browser-upload route. |
| `curl 401` | API key missing/wrong — re-`export ANTHROPIC_API_KEY`. |
| Same byte count every run | You re-ran the runner on the OLD bundle. Re-run the **collector** first. |

---

## Security

- **Never commit or paste API keys.** If a key is exposed, revoke it immediately.
- Use least-privilege (read-only) credentials for analysis where possible.
- Always back up etcd and validate on **non-prod** before production.

---


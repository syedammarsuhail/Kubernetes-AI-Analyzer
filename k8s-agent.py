#!/usr/bin/env python3
"""
k8s-agent.py — human-in-the-loop Kubernetes remediation agent.

Reads an upgrade-assessment report, then drives a Claude tool-use loop that:
  * runs READ-ONLY kubectl automatically (get/describe/version/top/...)
  * STOPS and asks YOU before running any change (apply/patch/delete/scale/...)
  * defaults to DRY-RUN (proposes, executes nothing) unless you pass --apply
  * never fakes verification — items it can't confirm are left for you

It improves readiness; it does NOT chase a "100" score. Architectural items
(HA control plane) and vendor-matrix checks are reported, not auto-applied.

Usage:
  export ANTHROPIC_API_KEY=sk-ant-...
  # Plan only (safe, touches nothing):
  python3 k8s-agent.py --report report.md --context my-ctx
  # Execute, approving each change interactively:
  python3 k8s-agent.py --report report.md --context my-ctx --apply
  # Auto-apply ONLY low-risk reversible changes, prompt for the rest:
  python3 k8s-agent.py --report report.md --context my-ctx --apply --auto-safe

Strongly recommended: run against a NON-PROD cluster first.
"""
import argparse, json, os, subprocess, sys, urllib.request

API_URL = "https://api.anthropic.com/v1/messages"
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-8")

# kubectl verbs that only READ — auto-executed, never gated
READONLY = {"get", "describe", "version", "top", "api-resources", "api-versions",
            "explain", "cluster-info", "logs", "auth"}
# patterns that are catastrophic — ALWAYS require typed confirmation even with --auto-safe
DANGER = ("delete namespace", "delete ns", "delete pv", "delete crd",
          "delete customresourcedefinition", "drain", "cordon", "upgrade apply",
          "delete --all", "--all-namespaces --all", "delete node")

TOOLS = [
    {"name": "kubectl_read",
     "description": "Run a READ-ONLY kubectl command (get/describe/version/top/api-resources/logs). "
                    "Executed automatically. Do NOT use for changes.",
     "input_schema": {"type": "object",
                      "properties": {"args": {"type": "string",
                                              "description": "kubectl arguments, e.g. 'get deploy -n kube-system coredns -o yaml'"}},
                      "required": ["args"]}},
    {"name": "propose_change",
     "description": "Propose a single MUTATING action (apply/patch/scale/delete/etc). "
                    "Requires human approval before it runs. Provide a verify command to confirm success.",
     "input_schema": {"type": "object",
                      "properties": {
                          "command": {"type": "string", "description": "Full shell command to run, e.g. 'kubectl -n kube-system scale deploy coredns --replicas=3'"},
                          "why": {"type": "string"},
                          "risk": {"type": "string", "enum": ["low", "medium", "high"]},
                          "reversible": {"type": "boolean"},
                          "verify": {"type": "string", "description": "read-only command to confirm the change worked"}},
                      "required": ["command", "why", "risk", "reversible"]}},
    {"name": "finish",
     "description": "End the session with a summary of what was done and what remains for a human.",
     "input_schema": {"type": "object",
                      "properties": {
                          "summary": {"type": "string"},
                          "manual_items": {"type": "array", "items": {"type": "string"}},
                          "notes": {"type": "string"}},
                      "required": ["summary"]}},
]

SYSTEM = """You are a careful Senior Kubernetes SRE remediating a cluster ahead of an upgrade.
You have read-only and (human-gated) change tools.

Rules:
- Use kubectl_read freely to inspect before acting. Verify the real state; do not assume.
- Propose changes ONE at a time via propose_change, smallest reversible step first.
- Order: backups and safety first, then low-risk reversible fixes, then riskier ones.
- NEVER propose destructive actions (delete namespace/pv/crd, drain, kubeadm upgrade apply)
  unless they are clearly safe AND you explain blast radius; expect the human to refuse.
- Some findings CANNOT be fixed by a command (e.g. single non-HA control plane) — do not
  pretend; list them for the human via finish().manual_items.
- Do not chase a numeric score. Fix real risks; stop when the safe, reversible work is done.
- If a verify step shows failure, stop and report rather than piling on more changes.
- Call finish() when done or when only human-decision items remain."""


def call_api(messages):
    body = json.dumps({"model": MODEL, "max_tokens": 4000, "system": SYSTEM,
                       "tools": TOOLS, "messages": messages}).encode()
    req = urllib.request.Request(API_URL, data=body, headers={
        "x-api-key": os.environ["ANTHROPIC_API_KEY"],
        "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def run(cmd, ctx):
    full = cmd if "--context" in cmd or not cmd.strip().startswith("kubectl") else cmd.replace("kubectl", f"kubectl --context={ctx}", 1)
    p = subprocess.run(full, shell=True, capture_output=True, text=True, timeout=120)
    return (p.stdout + p.stderr).strip()[:6000] or "(no output)"


def is_readonly(args):
    toks = args.split()
    return bool(toks) and toks[0] in READONLY


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--context", required=True, help="kubectl context (explicit, to avoid wrong cluster)")
    ap.add_argument("--apply", action="store_true", help="actually execute approved changes (default: dry-run)")
    ap.add_argument("--auto-safe", action="store_true", help="auto-approve low-risk reversible changes")
    ap.add_argument("--max-steps", type=int, default=40)
    a = ap.parse_args()

    if "ANTHROPIC_API_KEY" not in os.environ:
        sys.exit("set ANTHROPIC_API_KEY")
    report = open(a.report).read()
    mode = "APPLY" if a.apply else "DRY-RUN (nothing will be executed)"
    print(f"== k8s remediation agent ==  context={a.context}  mode={mode}")
    print("   (read-only commands auto-run; changes need your approval)\n")

    messages = [{"role": "user", "content":
                 f"Cluster context: {a.context}\n\nUpgrade assessment report:\n\n{report}\n\n"
                 "Inspect the live cluster and remediate the safe, reversible findings. "
                 "Gate every change through me. List human-only items at the end."}]

    for _ in range(a.max_steps):
        resp = call_api(messages)
        messages.append({"role": "assistant", "content": resp["content"]})
        results = []
        stop = False
        for block in resp["content"]:
            if block["type"] == "text" and block["text"].strip():
                print("AGENT:", block["text"].strip(), "\n")
            elif block["type"] == "tool_use":
                name, inp, tid = block["name"], block["input"], block["id"]
                if name == "kubectl_read":
                    args = inp.get("args", "")
                    if not is_readonly(args):
                        out = "REFUSED: not a read-only verb. Use propose_change for mutations."
                    else:
                        print(f"  [read] kubectl {args}")
                        out = run(f"kubectl {args}", a.context)
                    results.append({"type": "tool_result", "tool_use_id": tid, "content": out})
                elif name == "propose_change":
                    cmd = inp["command"]; risk = inp.get("risk", "medium")
                    rev = inp.get("reversible", False); verify = inp.get("verify", "")
                    danger = any(d in cmd.lower() for d in DANGER)
                    print("  ── PROPOSED CHANGE ─────────────────────────────")
                    print(f"   command : {cmd}")
                    print(f"   why     : {inp.get('why','')}")
                    print(f"   risk    : {risk}  reversible={rev}  danger={danger}")
                    if verify: print(f"   verify  : {verify}")
                    if not a.apply:
                        print("   -> DRY-RUN: not executed.\n")
                        results.append({"type": "tool_result", "tool_use_id": tid,
                                        "content": "DRY-RUN: not executed. Continue planning the next step."})
                        continue
                    auto = a.auto_safe and risk == "low" and rev and not danger
                    if auto:
                        print("   -> auto-approved (low-risk, reversible)")
                        ok = True
                    elif danger:
                        ok = input(f"   DANGEROUS. Type the word APPLY to run, anything else to skip: ") == "APPLY"
                    else:
                        ok = input("   Run this? [y/N]: ").strip().lower() == "y"
                    if not ok:
                        print("   -> skipped by user.\n")
                        results.append({"type": "tool_result", "tool_use_id": tid,
                                        "content": "User SKIPPED this change. Propose an alternative or move on."})
                        continue
                    out = run(cmd, a.context)
                    print(f"   result: {out[:500]}")
                    if verify and is_readonly(verify.replace("kubectl", "", 1).split()[0] if verify.startswith("kubectl") else verify):
                        vout = run(verify, a.context)
                        print(f"   verify result: {vout[:500]}")
                        out += f"\n\nVERIFY:\n{vout}"
                    print()
                    results.append({"type": "tool_result", "tool_use_id": tid, "content": out})
                elif name == "finish":
                    print("\n== DONE ==")
                    print(inp.get("summary", ""))
                    if inp.get("manual_items"):
                        print("\nHuman-decision items (NOT auto-fixed):")
                        for m in inp["manual_items"]:
                            print("  -", m)
                    if inp.get("notes"):
                        print("\nNotes:", inp["notes"])
                    stop = True
        if stop:
            break
        if results:
            messages.append({"role": "user", "content": results})
        else:
            break
    else:
        print("\n(reached max steps)")


if __name__ == "__main__":
    main()

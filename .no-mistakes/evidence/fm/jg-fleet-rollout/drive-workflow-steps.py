#!/usr/bin/env python3
"""Drive the JevGate workflow's own step scripts against the pinned JevGate binary."""
import os, subprocess, sys, yaml, tempfile, shutil
REPO = "/tmp/jg-test-01M3B8W/repo"
JG_BIN = "/tmp/jg-test-01M3B8W/root/bin"
BASE = "b42d4fa8a752fad9a5f0235783b02534bce29219"
wf = yaml.safe_load(open(f"{REPO}/.github/workflows/jevgate.yml"))
job = wf["jobs"]["review"]
steps = {s.get("name"): s for s in job["steps"]}
resolve = steps["Resolve the review policy"]["run"]
review = steps["Review the changed files"]

def sh(script, cwd, env_extra, label):
    env = {k: v for k, v in os.environ.items() if "KEY" not in k and "TOKEN" not in k}
    env["PATH"] = JG_BIN + ":" + env["PATH"]
    env.update(env_extra)
    print(f"\n$ [{label}] (cwd={cwd})\n$ {script.strip()}")
    p = subprocess.run(["bash", "-eo", "pipefail", "-c", script], cwd=cwd, env=env,
                       capture_output=True, text=True)
    print(p.stdout.rstrip()); print(p.stderr.rstrip()) if p.stderr.strip() else None
    print(f"[exit {p.returncode}]")
    return p

mode = sys.argv[1]
rt = tempfile.mkdtemp(prefix="runner-temp-", dir="/tmp/jg-test-01M3B8W")
env = {"BASE_SHA": BASE, "RUNNER_TEMP": rt, "CI": "true", "GITHUB_ACTIONS": "true",
       "GITHUB_STEP_SUMMARY": f"{rt}/summary.md"}
open(env["GITHUB_STEP_SUMMARY"], "w").close()
if mode == "self":
    sh(resolve, REPO, env, "Resolve the review policy")
    print("--- resolved policy ---"); print(open(f"{rt}/jevgate.toml").read())
    cmd = review["run"] + " --dry-run"
    sh(cmd, REPO, env, "Review the changed files (+ --dry-run)")
    print("\n--- no OPENROUTER_API_KEY (secret unset): exact workflow command ---")
    p = sh(review["run"], REPO, env, "Review the changed files")
    print("--- step summary ---"); print(open(env["GITHUB_STEP_SUMMARY"]).read())

def fixture(base_policy):
    d = tempfile.mkdtemp(prefix="fixture-", dir="/tmp/jg-test-01M3B8W")
    g = lambda *a: subprocess.run(["git", *a], cwd=d, check=True, capture_output=True)
    g("init", "-q", "-b", "main"); g("config", "user.email", "t@t"); g("config", "user.name", "t")
    open(f"{d}/README.md", "w").write("fixture\n")
    if base_policy is not None:
        open(f"{d}/jevgate.toml", "w").write(base_policy)
    g("add", "-A"); g("commit", "-qm", "base")
    base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=d, capture_output=True, text=True).stdout.strip()
    return d, base, g

if mode in ("loosen", "deny"):
    strict = 'provider = "openrouter"\nmodel = "typesafe/jev-latest"\nmax_requests = 10\nfail_on = ["review"]\n'
    d, base, g = fixture(strict if mode == "loosen" else None)
    # The pull request head: this change's jevgate.toml plus application source and secret-looking source.
    shutil.copy(f"{REPO}/jevgate.toml", f"{d}/jevgate.toml")
    os.makedirs(f"{d}/settings")
    open(f"{d}/app.py", "w").write("\n".join([f"def handler_{i}(order):\n    total = 0\n    for line in order['lines']:\n        if line['qty'] > 0:\n            if line['price'] > 100:\n                total += line['qty'] * line['price'] * 0.9\n            else:\n                total += line['qty'] * line['price']\n    return total\n" for i in range(14)]))
    open(f"{d}/settings/.env.local.js", "w").write("const API_TOKEN = 'SENTINEL-SECRET-VALUE';\n" + "\n".join([f"function load{i}(cfg) {{\n  let out = {{}};\n  for (const k of Object.keys(cfg)) {{\n    if (cfg[k] !== undefined) {{\n      if (k.startsWith('x')) {{ out[k] = cfg[k] * 2; }}\n      else {{ out[k] = cfg[k]; }}\n    }}\n  }}\n  return out;\n}}\n" for i in range(14)]) + "module.exports = { API_TOKEN };\n")
    g("add", "-A"); g("commit", "-qm", "head")
    env["BASE_SHA"] = base
    print(f"fixture repo {d}; base {base} ({'has strict jevgate.toml' if mode=='loosen' else 'no jevgate.toml'})")
    sh(resolve, d, env, "Resolve the review policy")
    print("--- resolved policy ---"); print(open(f"{rt}/jevgate.toml").read())
    p = sh(review["run"].replace(" --format github", "") + " --dry-run --show-requests", d, env,
           "Review the changed files (+ --dry-run --show-requests)")
    print("SENTINEL-SECRET-VALUE uploaded?", "SENTINEL-SECRET-VALUE" in p.stdout)
    print("app.py uploaded?", "def handler_" in p.stdout)
    print("settings/.env.local.js selected?", ".env.local.js" in p.stdout)
    if mode == "deny":
        nodeny = open(f"{rt}/jevgate.toml").read().split("# Keep common")[0]
        open(f"{rt}/nodeny.toml", "w").write(nodeny)
        c = sh(review["run"].replace(" --format github", "").replace("$RUNNER_TEMP/jevgate.toml", "$RUNNER_TEMP/nodeny.toml") + " --dry-run --show-requests", d, env,
               "control: same policy WITHOUT upload_deny")
        print("control: SENTINEL-SECRET-VALUE would be uploaded?", "SENTINEL-SECRET-VALUE" in c.stdout)
    if mode == "deny":
        sh(review["run"], d, env, "Review the changed files (exact command, OPENROUTER_API_KEY unset)")
        env2 = dict(env, OPENROUTER_API_KEY="sk-or-FAKE-SENTINEL-KEY-0000")
        p = sh(review["run"] + " --dry-run", d, env2, "dry-run with a sentinel OPENROUTER_API_KEY present")
        print("sentinel key printed?", "FAKE-SENTINEL" in p.stdout + p.stderr)
        # Adversarial control: the consumer really validates this config (a bad provider is rejected).
        bad = open(f"{rt}/jevgate.toml").read().replace('"openrouter"', '"not-a-provider"')
        open(f"{rt}/bad.toml", "w").write(bad)
        sh('jevgate check --config "$RUNNER_TEMP/bad.toml" --base "$BASE_SHA" --dry-run', d, env,
           "control: same policy with an invalid provider")

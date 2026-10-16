#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Simple Zephyr test runner for this BSP (builds + runs on Spike).

Fallback/simple path next to `west twister` (`make test` calls it). Run `--help` for flags,
`--list` to see scenarios. Needs west and the Zephyr SDK on PATH (see README.md). Spike is
optional: without it every scenario that needs to run is only built and reported BUILT
(one notice at the start), see --build-only.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import yaml

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
PASS, FAIL, SKIP, XFAIL, XPASS = "PASS", "FAIL", "SKIP", "XFAIL", "XPASS"
# BUILT = built fine but NOT run (Spike absent, or --build-only). Not a pass, not a failure.
BUILT = "BUILT"


# ---------------------------------------------------------------- discovery
def as_list(v):
    if v is None:
        return []
    if isinstance(v, str):
        return v.split()
    return list(v)


def discover(root):
    """Yield one scenario dict per entry under tests: in testcase.yaml/sample.yaml.

    The BSP itself keeps scenarios under tests/, samples/ and external/. Any other root (an app
    repo, see --root) is searched whole, minus hidden and build folders."""
    subs = ("tests", "samples", "external") if os.path.realpath(root) == REPO else (".",)
    for sub in subs:
        for dp, dn, fn in os.walk(os.path.join(root, sub)):
            dn[:] = sorted(d for d in dn if not d.startswith(".") and d not in ("build", "__pycache__"))
            for f in ("testcase.yaml", "sample.yaml"):
                if f not in fn:
                    continue
                with open(os.path.join(dp, f)) as fh:
                    doc = yaml.safe_load(fh) or {}
                common = doc.get("common") or {}
                for name, body in (doc.get("tests") or {}).items():
                    s = dict(common)
                    s.update(body or {})
                    # lists that accumulate in twister: common + scenario
                    for k in ("extra_configs", "extra_args", "tags"):
                        s[k] = as_list(common.get(k)) + as_list((body or {}).get(k))
                    s["name"] = name
                    s["path"] = dp
                    s["relpath"] = os.path.relpath(dp, root)
                    yield s


# ---------------------------------------------------------------- filtering
def read_config(builddir):
    cfg = {}
    try:
        with open(os.path.join(builddir, "zephyr", ".config")) as fh:
            for line in fh:
                m = re.match(r'(CONFIG_\w+)=(.*)', line.strip())
                if m:
                    v = m.group(2)
                    cfg[m.group(1)] = v.strip('"') if v.startswith('"') else v
    except OSError:
        pass
    return cfg


def eval_filter(expr, cfg):
    """Evaluate a twister-style filter (CONFIG_X and not CONFIG_Y, ==, !=).
    Unset symbols are False/"" ; y is True. Not supported: dt_* functions."""
    class Cfg(dict):
        def __missing__(self, k):
            return ""
    env = Cfg()
    for k, v in cfg.items():
        env[k] = True if v == "y" else (int(v) if re.fullmatch(r"-?\d+", v) else v)
    if re.search(r"\bdt_\w+\(", expr):
        raise ValueError("dt_* filter functions are not supported")
    return bool(eval(expr, {"__builtins__": {}}, env))  # trusted repo YAML


# Scenarios that read an external checkout carry a tag `needs_path:<ENVVAR>` in their
# sample.yaml (a tag, because twister rejects unknown keys but accepts any tag). The
# runner SKIPs them with a reason instead of letting the build FAIL when the checkout is
# absent. Add a row here to guard another dependency. No default location: the variable (or the
# sample's -D) must be set, same as in the sample's CMake.
EXTERNAL_PATHS = {
    "TAPEOUT_CHIPYARD": dict(
        marker=os.path.join("tests", "atlas_mmio.h"),
        what="the course tapeout repo (Atlas/Saturn host tests)"),
}


def missing_external(s):
    """Return a SKIP reason if a `needs_path:` tag points at a checkout that is absent."""
    for tag in s.get("tags", []):
        if not tag.startswith("needs_path:"):
            continue
        var = tag.split(":", 1)[1]
        info = EXTERNAL_PATHS.get(var, {})
        path = os.environ.get(var, "")
        marker = info.get("marker", "")
        if not path or not os.path.exists(os.path.join(path, marker)):
            return ("needs %s: set %s=<checkout> (looked in %r for %s)"
                    % (info.get("what", var), var, path, marker or "the directory"))
    return None


def static_skip(s, board):
    if s.get("skip"):  # twister key: never build (the reason is in the scenario's comment/tags)
        return "skip: true in the scenario (tags: %s)" % (" ".join(s["tags"]) or "-")
    pa = as_list(s.get("platform_allow"))
    if pa and board not in pa and board.split("/")[0] not in pa:
        return "platform_allow does not list %s" % board
    if board in as_list(s.get("platform_exclude")):
        return "platform_exclude lists %s" % board
    return None


# ---------------------------------------------------------------- spike
def find_spike():
    """Same lookup order as cmake/spike.cmake: $SPIKE, else `spike` on PATH. Return path or None."""
    return shutil.which(os.environ.get("SPIKE") or "spike")


# ---------------------------------------------------------------- west helpers
def west_out(*args):
    """Run `west <args>`; return its stripped output, or '' if west fails or is absent."""
    try:
        return subprocess.check_output(["west", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, OSError):
        return ""


def west_topdir():
    """The west workspace (folder with .west/); falls back to the parent of this checkout."""
    return west_out("topdir") or os.path.dirname(REPO)


def detect_modules(override):
    """Value for -DZEPHYR_MODULES, or None when west already knows this checkout.

    West knows it when it is the manifest repository itself (the BSP's own workspace) or a west
    project named chipyard-bsp (an app repo that imports the BSP). Only a different checkout
    (e.g. a git worktree under review) needs the override, or Zephyr would build the wrong code."""
    if override:
        return override
    known = [west_out("list", "-f", "{abspath}", name).splitlines()[:1] for name in ("manifest", "chipyard-bsp")]
    for k in known:
        if k and os.path.realpath(k[0]) == REPO:
            return None
    return REPO if any(known) else None


def run_cmd(cmd, log, timeout, env=None):
    """Run cmd, tee to log file, kill whole process group on timeout."""
    with open(log, "w") as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                             start_new_session=True, env=env)
        try:
            rc = p.wait(timeout=timeout)
            return rc, False
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            return None, True


def harness_ok(s, out):
    """Return (ok, why)."""
    h = s.get("harness")
    if h == "ztest":
        if "PROJECT EXECUTION SUCCESSFUL" in out:
            return True, ""
        m = re.search(r"PROJECT EXECUTION FAILED", out)
        return False, "ztest reported FAILED" if m else "no ztest summary in output"
    if h in ("console", "test"):
        cfg = s.get("harness_config") or {}
        for rx in as_list_regex(cfg.get("regex")):
            if not re.search(rx, out, re.M):
                return False, "regex not found: %s" % rx
        return True, ""
    return True, ""  # no harness: exit code decides


def as_list_regex(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


# ---------------------------------------------------------------- one scenario
def run_one(s, a, modules):
    t0 = time.time()
    r = {"name": s["name"], "path": s["relpath"], "status": FAIL, "detail": "",
         "build_s": 0.0, "run_s": 0.0}
    sk = static_skip(s, a.board) or missing_external(s)
    if sk:
        r.update(status=SKIP, detail=sk)
        return r
    bdir = os.path.join(a.build_root, s["name"])
    os.makedirs(bdir, exist_ok=True)
    r["log"] = bdir
    cmd = ["west", "build", "-p", "auto" if a.incremental else "always",
           "-b", a.board, "-d", bdir, s["path"], "--"]
    if modules:
        cmd.append("-DZEPHYR_MODULES=" + modules)
    cmd += ["-D" + c if not c.startswith("-D") else c for c in s["extra_configs"]]
    # twister-style extra_args are bare VAR=value (twister adds the -D)
    cmd += ["-D" + c if re.match(r"^\w+=", c) else c for c in s["extra_args"]]
    rc, to = run_cmd(cmd, os.path.join(bdir, "build.log"), a.build_timeout)
    r["build_s"] = round(time.time() - t0, 1)
    if to or rc != 0:
        r["detail"] = "build timed out" if to else "build failed (see build.log)"
        return r
    cfg = read_config(bdir)
    if "arch_allow" in s and cfg.get("CONFIG_ARCH") not in as_list(s["arch_allow"]):
        r.update(status=SKIP, detail="arch_allow: %s" % s["arch_allow"])
        return r
    if s.get("filter"):
        try:
            ok = eval_filter(s["filter"], cfg)
        except Exception as e:  # noqa
            r["detail"] = "cannot evaluate filter %r: %s" % (s["filter"], e)
            return r
        if not ok:
            r.update(status=SKIP, detail="filter false: %s" % s["filter"])
            return r
    if s.get("build_only"):  # twister key: needs hardware the runner lacks (e.g. Atlas)
        r.update(status=PASS, detail="build only")
        return r
    if not a.run:  # Spike absent or --build-only: built is all we can say
        r.update(status=BUILT, detail=a.no_run_reason)
        return r
    t1 = time.time()
    tmo = s.get("timeout", a.timeout)
    env = dict(os.environ, SPIKE_TIMEOUT=str(tmo))
    rc, to = run_cmd(["west", "build", "-d", bdir, "-t", "run"],
                     os.path.join(bdir, "run.log"), tmo + 30, env)
    r["run_s"] = round(time.time() - t1, 1)
    out = open(os.path.join(bdir, "run.log"), errors="replace").read()
    if to or rc in (124, 137):
        r["detail"] = "run timed out after %ss" % tmo
        return r
    ok, why = harness_ok(s, out)
    if rc != 0:
        r["detail"] = "run exit code %s%s" % (rc, "; " + why if why else "")
    elif not ok:
        r["detail"] = why
    else:
        r["status"] = PASS
    return r


# ---------------------------------------------------------------- reporting
def write_junit(path, results, board):
    suite = ET.Element("testsuite", name="zephyr-chipyard-bsp:" + board,
                       tests=str(len(results)),
                       failures=str(sum(r["status"] in (FAIL, XPASS_FAILS) for r in results)),
                       skipped=str(sum(r["status"] in (SKIP, XFAIL, BUILT) for r in results)))
    for r in results:
        tc = ET.SubElement(suite, "testcase", classname=r["path"], name=r["name"],
                           time=str(round(r["build_s"] + r["run_s"], 1)))
        if r["status"] == FAIL:
            ET.SubElement(tc, "failure", message=r["detail"])
        elif r["status"] == XPASS:
            ET.SubElement(tc, "failure", message="XPASS: " + r["detail"])
        elif r["status"] in (SKIP, XFAIL, BUILT):
            ET.SubElement(tc, "skipped", message="%s: %s" % (r["status"], r["detail"]))
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


XPASS_FAILS = XPASS  # XPASS only counted as failure in JUnit; exit code uses --strict-xpass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board", default="chipyard_penguin/penguin")
    ap.add_argument("-f", "--filter", action="append", default=[], metavar="SUBSTR",
                    help="keep scenarios whose name or tag contains SUBSTR (repeatable; any match)")
    ap.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2),
                    help="parallel scenarios (build+run each)")
    ap.add_argument("--modules", help="explicit ZEPHYR_MODULES value (default: auto-detect)")
    ap.add_argument("--root", default=REPO, metavar="DIR",
                    help="scenario root: the folder whose sample.yaml/testcase.yaml files are run "
                         "(default: this BSP). Use it to run an app repo's suite; "
                         "known failures then default to <DIR>/known_failures.yaml")
    ap.add_argument("--known-failures", default=None,
                    help="known-failures YAML (default: <root>/known_failures.yaml, or tests/known_failures.yaml for the BSP)")
    ap.add_argument("--strict-xpass", action="store_true", help="XPASS fails the run")
    ap.add_argument("--build-root", default=None,
                    help="where builds and logs go (default: <west topdir>/build/test-runner)")
    ap.add_argument("--timeout", type=int, default=300, help="seconds per Spike run (default 300)")
    ap.add_argument("--build-timeout", type=int, default=900)
    ap.add_argument("--build-only", action="store_true",
                    help="build every scenario but do not run any (reported BUILT); implied, with a "
                         "notice, when Spike is not found")
    ap.add_argument("--incremental", action="store_true", help="west -p auto instead of always")
    ap.add_argument("--junit", metavar="FILE")
    ap.add_argument("--json", metavar="FILE")
    ap.add_argument("--list", action="store_true", help="list scenarios and exit")
    a = ap.parse_args()
    a.build_root = os.path.abspath(a.build_root or os.path.join(west_topdir(), "build", "test-runner"))
    os.makedirs(a.build_root, exist_ok=True)

    a.root = os.path.realpath(a.root)
    if a.known_failures is None:
        a.known_failures = os.path.join(a.root, "known_failures.yaml" if a.root != REPO else "tests/known_failures.yaml")
    scen = list(discover(a.root))
    if a.filter:
        scen = [s for s in scen if any(f in s["name"] or any(f in t for t in s["tags"])
                                       for f in a.filter)]
    if a.list:
        for s in scen:
            print(s["name"], s["relpath"], " ".join(s["tags"]))
        return 0
    known = {}
    if os.path.exists(a.known_failures):
        for k in (yaml.safe_load(open(a.known_failures)) or {}).get("known_failures", []):
            known[k["id"]] = k
    modules = detect_modules(a.modules)
    spike = find_spike()
    a.run = spike is not None and not a.build_only
    a.no_run_reason = "built, not run (--build-only)"
    if spike is None and not a.build_only:
        a.no_run_reason = "built, not run (Spike not found)"
        print("NOTICE: Spike not found (looked for %r): scenarios that need to run are only BUILT, "
              "not run. Set SPIKE=/path/to/spike or run setup with --with-spike to run them."
              % (os.environ.get("SPIKE") or "spike"), flush=True)
    print("board=%s jobs=%d modules=%s scenarios=%d" %
          (a.board, a.jobs, modules or "(west default)", len(scen)), flush=True)

    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(run_one, s, a, modules): s for s in scen}
        for f in cf.as_completed(futs):
            r = f.result()
            k = known.get(r["name"])
            if k:
                r["known"] = k.get("reason", "")
                if r["status"] == FAIL:
                    r["status"] = XFAIL
                    r["detail"] = "%s; known: see tests/known_failures.yaml" % r["detail"]
                elif r["status"] == PASS:
                    r["status"] = XPASS
                    r["detail"] = "now passes: remove from known_failures.yaml" + (
                        " (fixed_by: %s)" % k["fixed_by"] if k.get("fixed_by") else "")
            print("  %-6s %s" % (r["status"], r["name"]), flush=True)
            results.append(r)
    results.sort(key=lambda r: r["name"])

    w = max([len(r["name"]) for r in results] + [4])
    print("\n%-*s  %-6s %7s %6s  %s" % (w, "TEST", "RESULT", "BUILD s", "RUN s", "DETAIL"))
    for r in results:
        print("%-*s  %-6s %7.1f %6.1f  %s" % (w, r["name"], r["status"], r["build_s"],
                                              r["run_s"], r["detail"]))
    cnt = {k: sum(r["status"] == k for r in results) for k in (PASS, FAIL, SKIP, XFAIL, XPASS, BUILT)}
    # The summary line keeps its usual shape; BUILT=n is appended only when something was not run.
    print("\n" + "  ".join("%s=%d" % kv for kv in cnt.items() if kv[0] != BUILT or kv[1]))
    print("logs: " + a.build_root)
    if a.json:
        json.dump({"board": a.board, "summary": cnt, "results": results},
                  open(a.json, "w"), indent=2)
    if a.junit:
        write_junit(a.junit, results, a.board)
    bad = cnt[FAIL] + (cnt[XPASS] if a.strict_xpass else 0)
    if cnt[XPASS]:
        print("NOTE: %d XPASS: prune tests/known_failures.yaml" % cnt[XPASS])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

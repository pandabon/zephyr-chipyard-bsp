#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build and run the testcase.yaml/sample.yaml scenarios on Spike (`make test`).

A small alternative to `west twister`, which the stock Spike board YAML breaks (see
patches/zephyr/0004). `--list` shows the scenarios. Needs west, spike and the Zephyr SDK
on PATH.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import yaml

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
PASS, FAIL, SKIP, XFAIL, XPASS = "PASS", "FAIL", "SKIP", "XFAIL", "XPASS"


# ---------------------------------------------------------------- discovery
def as_list(v):
    if v is None:
        return []
    if isinstance(v, str):
        return v.split()
    return list(v)


def discover(root):
    """Yield one scenario dict per entry under tests: in testcase.yaml/sample.yaml."""
    for sub in ("tests", "samples"):
        for dp, dn, fn in os.walk(os.path.join(root, sub)):
            dn.sort()
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
    Unset symbols are "" and y is True. dt_* functions are not supported."""
    class Cfg(dict):
        def __missing__(self, k):
            return ""
    env = Cfg()
    for k, v in cfg.items():
        env[k] = True if v == "y" else (int(v) if re.fullmatch(r"-?\d+", v) else v)
    if re.search(r"\bdt_\w+\(", expr):
        raise ValueError("dt_* filter functions are not supported")
    return bool(eval(expr, {"__builtins__": {}}, env))  # trusted repo YAML


# A scenario tagged `needs_path:<ENVVAR>` is SKIPped when that external checkout is absent.
# (A tag, because twister rejects unknown keys.) Defaults match the sample's CMake.
EXTERNAL_PATHS = {
    "TAPEOUT_CHIPYARD": dict(
        default=os.path.join(os.path.expanduser("~"), "toolsB", "tapeout-chipyard"),
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
        path = os.environ.get(var) or info.get("default", "")
        marker = info.get("marker", "")
        if not path or not os.path.exists(os.path.join(path, marker)):
            return ("needs %s: set %s=<checkout> (looked in %r for %s)"
                    % (info.get("what", var), var, path, marker or "the directory"))
    return None


def static_skip(s, board):
    pa = as_list(s.get("platform_allow"))
    if pa and board not in pa and board.split("/")[0] not in pa:
        return "platform_allow does not list %s" % board
    if board in as_list(s.get("platform_exclude")):
        return "platform_exclude lists %s" % board
    return None


# ---------------------------------------------------------------- west helpers
def detect_modules(override):
    if override:
        return override
    try:
        mf = subprocess.check_output(["west", "manifest", "--path"], text=True).strip()
        manifest_dir = os.path.dirname(os.path.realpath(mf))
        if manifest_dir == REPO:
            return None
        return REPO
    except (subprocess.CalledProcessError, OSError):
        return None


def run_cmd(cmd, log, timeout, env=None):
    """Run cmd with output to log; kill the whole process group on timeout."""
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
    # extra_args are bare VAR=value, as in twister
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
    if s.get("build_only"):  # e.g. Atlas, which Spike lacks
        r.update(status=PASS, detail="build only")
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
                       skipped=str(sum(r["status"] in (SKIP, XFAIL) for r in results)))
    for r in results:
        tc = ET.SubElement(suite, "testcase", classname=r["path"], name=r["name"],
                           time=str(round(r["build_s"] + r["run_s"], 1)))
        if r["status"] == FAIL:
            ET.SubElement(tc, "failure", message=r["detail"])
        elif r["status"] == XPASS:
            ET.SubElement(tc, "failure", message="XPASS: " + r["detail"])
        elif r["status"] in (SKIP, XFAIL):
            ET.SubElement(tc, "skipped", message="%s: %s" % (r["status"], r["detail"]))
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


XPASS_FAILS = XPASS  # JUnit counts XPASS as a failure; the exit code needs --strict-xpass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board", default="chipyard_penguin/penguin")
    ap.add_argument("-f", "--filter", action="append", default=[], metavar="SUBSTR",
                    help="keep scenarios whose name or tag contains SUBSTR (repeatable; any match)")
    ap.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2),
                    help="parallel scenarios (build+run each)")
    ap.add_argument("--modules", help="explicit ZEPHYR_MODULES value (default: auto-detect)")
    ap.add_argument("--known-failures", default=os.path.join(REPO, "tests", "known_failures.yaml"))
    ap.add_argument("--strict-xpass", action="store_true", help="XPASS fails the run")
    ap.add_argument("--build-root", default=os.path.join(os.path.dirname(REPO), "build", "test-runner"))
    ap.add_argument("--timeout", type=int, default=300, help="seconds per Spike run (default 300)")
    ap.add_argument("--build-timeout", type=int, default=900)
    ap.add_argument("--incremental", action="store_true", help="west -p auto instead of always")
    ap.add_argument("--junit", metavar="FILE")
    ap.add_argument("--json", metavar="FILE")
    ap.add_argument("--list", action="store_true", help="list scenarios and exit")
    a = ap.parse_args()
    a.build_root = os.path.abspath(a.build_root)
    os.makedirs(a.build_root, exist_ok=True)

    scen = list(discover(REPO))
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
    cnt = {k: sum(r["status"] == k for r in results) for k in (PASS, FAIL, SKIP, XFAIL, XPASS)}
    print("\n" + "  ".join("%s=%d" % kv for kv in cnt.items()))
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

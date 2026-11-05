#!/usr/bin/env python3
"""等云端 UI 测试跑完，然后把结论、步骤表、日志关键段、artifact 里的截图清单一次拉回来。

用法：
    python _ci_check.py                # 等最新的那次跑完
    python _ci_check.py --run 41948076790
"""

import io
import json
import os
import re
import sys
import time
import urllib.request
import zipfile

OWNER, REPO = "EddieZuiShuai", "PhotoOrganizer"
OUT_DIR = "_ci_artifacts"


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """GitHub 的 artifact / log 下载会 302 到对象存储，Authorization 跟着过去会被拒。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.headers.pop("Authorization", None)
        return new


_op = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoAuthRedirect())


def token():
    path = os.path.expanduser("~/.git-credentials")
    m = re.search(r"https://([^:]+):([^@]+)@github\.com", open(path, encoding="utf-8").read())
    if not m:
        raise SystemExit("没在 ~/.git-credentials 里找到 github token")
    return m.group(2)


TOK = token()


def api(path):
    req = urllib.request.Request("https://api.github.com" + path)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "wb-agent")
    with _op.open(req, timeout=60) as r:
        return json.loads(r.read())


def raw(path):
    req = urllib.request.Request("https://api.github.com" + path)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("User-Agent", "wb-agent")
    with _op.open(req, timeout=180) as r:
        return r.read()


def latest_run():
    runs = api("/repos/%s/%s/actions/runs?per_page=5" % (OWNER, REPO))["workflow_runs"]
    ui = [r for r in runs if r["name"].startswith("UI Tests")]
    return ui[0]


def wait(run_id, limit=1500):
    deadline = time.time() + limit
    last = None
    while time.time() < deadline:
        r = api("/repos/%s/%s/actions/runs/%s" % (OWNER, REPO, run_id))
        cur = (r["status"], r["conclusion"])
        if cur != last:
            print("  %s %s" % cur, flush=True)
            last = cur
        if r["status"] == "completed":
            return r
        time.sleep(20)
    raise SystemExit("等太久了，还没跑完")


def read_log(run_id):
    jobs = api("/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, run_id))["jobs"]
    job = [j for j in jobs if j["name"] == "iOS Simulator"][0]
    data = raw("/repos/%s/%s/actions/jobs/%s/logs" % (OWNER, REPO, job["id"]))
    if data[:2] == b"PK":
        z = zipfile.ZipFile(io.BytesIO(data))
        txt = z.read(z.namelist()[0]).decode("utf-8", "replace")
    else:
        txt = data.decode("utf-8-sig", "replace")
    return job, txt


def grab_artifacts(run_id):
    arts = api("/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, run_id))["artifacts"]
    if not arts:
        print("没有 artifact")
        return []
    os.makedirs(OUT_DIR, exist_ok=True)
    names = []
    for a in arts:
        blob = raw("/repos/%s/%s/actions/artifacts/%s/zip" % (OWNER, REPO, a["id"]))
        z = zipfile.ZipFile(io.BytesIO(blob))
        z.extractall(os.path.join(OUT_DIR, a["name"]))
        names = z.namelist()
    return names


def main():
    run_id = None
    if "--run" in sys.argv:
        run_id = sys.argv[sys.argv.index("--run") + 1]
    if run_id is None:
        r = latest_run()
        run_id = r["id"]
        print("最新运行：%s  (%s)" % (run_id, r["html_url"]))

    r = wait(run_id)
    print("\n结论：%s" % r["conclusion"])
    print("地址：%s" % r["html_url"])

    job, log = read_log(run_id)
    open("_joblog.txt", "w", encoding="utf-8").write(log)

    print("\n--- 步骤 ---")
    for s in job["steps"]:
        if s.get("conclusion") is None:
            continue
        mark = "OK " if s["conclusion"] == "success" else "-- "
        print("%s%s" % (mark, s["name"]))

    lines = [re.sub(r"^\S+Z ", "", l) for l in log.splitlines()]
    print("\n--- Maestro 输出 ---")
    started = False
    shown = 0
    for l in lines:
        if "maestro test" in l:
            started = True
        if started:
            if l.startswith("##[group]Run FIRST") or l.startswith("##[group]Run echo \"Maestro exit"):
                break
            if l.strip():
                print(l)
                shown += 1
                if shown > 120:
                    print("...（截断，完整见 _joblog.txt）")
                    break

    print("\n--- artifact ---")
    names = grab_artifacts(run_id)
    for n in names:
        print("  " + n)

    base = os.path.join(OUT_DIR, "maestro-results")
    for rel, label, n in [
        ("preflight/launch.txt", "simctl 启动输出", 20),
        ("preflight/hierarchy.txt", "Maestro 看到的界面元素", 90),
        ("hierarchy.txt", "Maestro 看到的界面元素", 90),
    ]:
        p = os.path.join(base, rel)
        if os.path.exists(p):
            print("\n--- %s (%s) ---" % (label, rel))
            body = open(p, encoding="utf-8", errors="replace").read().splitlines()
            print("\n".join(body[:n]))

    print("\n产物解到 %s/" % OUT_DIR)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()

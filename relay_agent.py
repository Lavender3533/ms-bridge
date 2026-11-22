#!/usr/bin/env python3
"""Relay agent: run jobs that arrive through a private ModelScope git repo.

Layout of the relay repo
  code/            files shipped to the machine (scripts, data)
  jobs/<id>.sh     a job; run once, in /workspace/work, with bash
  results/<id>.log live output (pushed every ~30 s while running)
  results/<id>.exit exit code when finished
  results/<id>/    anything the job copies there is shipped back

Usage on the machine:  python3 relay_agent.py <ModelScope access token>
"""
import http.cookiejar
import json
import os
import subprocess
import sys
import time
import urllib.request

API = "https://www.modelscope.cn/api/v1"
REPO_NAME = "relay"
HOME = "/workspace/relay"
WORK = "/workspace/work"


def login(token):
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(f"{API}/login", data=json.dumps({"AccessToken": token}).encode(),
                                 headers={"Content-Type": "application/json"})
    d = json.load(opener.open(req, timeout=30))
    if not d.get("Success"):
        sys.exit(f"login failed: {d.get('Message')}")
    return d["Data"]["AccessToken"], d["Data"]["Username"], opener


def git(*args, check=True):
    return subprocess.run(["git", "-C", HOME, *args], capture_output=True, text=True, check=check)


def sync(msg):
    git("add", "-A", "results")
    if git("diff", "--cached", "--quiet", check=False).returncode != 0:
        git("commit", "-q", "-m", msg)
    for _ in range(5):
        git("pull", "-q", "--rebase", check=False)
        if git("push", "-q", check=False).returncode == 0:
            return
        time.sleep(3)


def main():
    git_token, user, _ = login(sys.argv[1])
    url = f"https://oauth2:{git_token}@www.modelscope.cn/datasets/{user}/{REPO_NAME}.git"
    if not os.path.isdir(os.path.join(HOME, ".git")):
        subprocess.run(["git", "clone", "-q", url, HOME], check=True)
    git("remote", "set-url", "origin", url)
    git("config", "user.name", "relay-agent")
    git("config", "user.email", "relay@localhost")
    os.makedirs(os.path.join(HOME, "results"), exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    print(f"relay agent up: {user}/{REPO_NAME}", flush=True)
    running = {}           # id -> (Popen, log file handle)
    last_push = 0.0
    while True:
        git("pull", "-q", "--rebase", check=False)
        jobs = sorted(f[:-3] for f in os.listdir(os.path.join(HOME, "jobs")) if f.endswith(".sh")) \
            if os.path.isdir(os.path.join(HOME, "jobs")) else []
        for jid in jobs:
            log = os.path.join(HOME, "results", f"{jid}.log")
            if jid in running or os.path.exists(log):
                continue
            os.makedirs(os.path.join(HOME, "results", jid), exist_ok=True)
            fh = open(log, "w")
            env = dict(os.environ, RELAY=HOME, RESULT=os.path.join(HOME, "results", jid), PYTHONUNBUFFERED="1")
            p = subprocess.Popen(["bash", os.path.join(HOME, "jobs", f"{jid}.sh")], cwd=WORK, stdout=fh,
                                 stderr=subprocess.STDOUT, env=env)
            running[jid] = (p, fh)
            print(f"started {jid}", flush=True)
        changed = False
        for jid, (p, fh) in list(running.items()):
            if p.poll() is not None:
                fh.close()
                with open(os.path.join(HOME, "results", f"{jid}.exit"), "w") as f:
                    f.write(str(p.returncode))
                del running[jid]
                changed = True
                print(f"finished {jid} rc={p.returncode}", flush=True)
        if changed or (running and time.time() - last_push > 30):
            sync("results")
            last_push = time.time()
        time.sleep(10)


if __name__ == "__main__":
    main()

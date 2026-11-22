import subprocess, json, urllib.request, urllib.error, time, sys

# 从 git 凭证管理器读取 token（仅内部使用，不打印）
p = subprocess.run(
    ["git", "credential", "fill"],
    input="protocol=https\nhost=github.com\n\n",
    capture_output=True, text=True, timeout=20,
)
creds = {}
for line in p.stdout.splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        creds[k] = v
token = creds.get("password", "")
headers = {
    "Authorization": "token " + token,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "build-monitor",
}

def api(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw
    except Exception as e:
        return 0, str(e)

run_id = sys.argv[1] if len(sys.argv) > 1 else "45009677758"
base = "https://api.github.com/repos/3055909481/dart_simple_live/actions/runs/" + run_id
last_state = None
max_checks = 80  # 80 * 30s = 40min

for i in range(max_checks):
    s, run = api(base)
    if s != 200:
        print("[%02d] API error %s: %s" % (i, s, str(run)[:200]), flush=True)
        time.sleep(30)
        continue

    status = run.get("status")
    conclusion = run.get("conclusion")
    state = (status, conclusion)
    if state != last_state:
        print("[%02d] status=%s conclusion=%s" % (i, status, conclusion), flush=True)
        last_state = state

    # 打印各 job 状态变化
    sj, jobs = api(base + "/jobs?per_page=100")
    if sj == 200 and isinstance(jobs, dict) and jobs.get("jobs"):
        for j in jobs["jobs"]:
            print("     job %-28s %-12s %s" % (j["name"], j["status"], j.get("conclusion")), flush=True)

    if status == "completed":
        print("BUILD_COMPLETED conclusion=%s" % conclusion, flush=True)
        sa, arts = api(base + "/artifacts?per_page=100")
        if sa == 200 and isinstance(arts, dict):
            print("ARTIFACTS total=%s" % arts.get("total_count"), flush=True)
            for a in arts.get("artifacts", []):
                print("   ARTIFACT %s | size=%s | expired=%s" % (
                    a["name"], a["size"], a.get("expired")), flush=True)
                print("   URL %s" % a.get("archive_download_url"), flush=True)
        sys.exit(0 if conclusion == "success" else 1)

    time.sleep(30)

print("TIMEOUT waiting build", flush=True)
sys.exit(2)

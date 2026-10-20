#!/usr/bin/env zsh
set -euo pipefail

if (( $# < 1 )); then
  print -u2 'Usage: check-compliance.zsh <github-repository-url> [YYYY-MM-DD]'
  exit 2
fi

url="$1"
repo="${url#https://github.com/}"
repo="${repo#git@github.com:}"
repo="${repo%.git}"
repo="${repo%/}"
if [[ ! "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
  print -u2 'Expected https://github.com/OWNER/REPO or git@github.com:OWNER/REPO.git'
  exit 2
fi
command -v gh >/dev/null || { print -u2 'GitHub CLI (gh) required'; exit 2; }
command -v python3 >/dev/null || { print -u2 'python3 required'; exit 2; }

export TZ=Europe/Amsterdam
report_date="${2:-$(TZ=Europe/Amsterdam date +%F)}"
[[ "$report_date" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] || { print -u2 'Invalid date format'; exit 2; }

# Python calculates local windows and checks the GitHub commit API.
# gh api --paginate returns all pages for the specified time interval.
export REPO="$repo" REPORT_DATE="$report_date"
python3 - <<'PY'
import datetime as dt
import json
import os
import subprocess
import sys
from zoneinfo import ZoneInfo

repo = os.environ['REPO']
day = dt.date.fromisoformat(os.environ['REPORT_DATE'])
tz = ZoneInfo('Europe/Amsterdam')
now = dt.datetime.now(tz)

def gh_api(path, *args):
    proc = subprocess.run(['gh', 'api', path, *args], text=True, capture_output=True)
    if proc.returncode:
        raise RuntimeError(proc.stderr.strip() or f'gh api failed: {path}')
    return json.loads(proc.stdout)

def utc_iso(t):
    return t.astimezone(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

try:
    if day.weekday() >= 5:
        print(f'SKIP {day}: weekend')
        sys.exit(0)
    if day > now.date():
        print('FAIL: future date')
        sys.exit(1)

    windows = [(label, dt.datetime.combine(day, dt.time(hour, 0), tz), hour)
               for label, hour in [('noon', 12), ('afternoon', 17)]]
    results = []
    for label, target, hour in windows:
        start = target - dt.timedelta(minutes=30)
        end = target + dt.timedelta(minutes=30)
        if now < end and day == now.date():
            print(f'PENDING {label}: window ends at {end:%H:%M %Z}')
            continue
        # GitHub commits endpoint lists commits reachable from the default branch.
        # For all branch tips, enumerate refs and deduplicate by SHA.
        branches = gh_api(f'repos/{repo}/branches', '--paginate')
        shas = set()
        for branch in branches:
            name = branch['name']
            from urllib.parse import quote
            commits = gh_api(f'repos/{repo}/commits?sha={quote(name, safe="")}&since={utc_iso(start)}&until={utc_iso(end)}&per_page=100', '--paginate')
            for commit in commits:
                stamp = commit['commit']['committer']['date']
                moment = dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                if start <= moment.astimezone(tz) <= end:
                    shas.add(commit['sha'])
        passed = bool(shas)
        results.append(passed)
        print(f'{"PASS" if passed else "FAIL"} {label} {start:%H:%M}–{end:%H:%M}: {len(shas)} commit(s)')

    # Check log file on default branch (the official submitted repository state).
    if day == now.date() and now < dt.datetime.combine(day, dt.time(17, 30), tz):
        print('PENDING log: evaluated after 17:30')
    else:
        from urllib.parse import quote
        path = f'log/{day.isoformat()}.md'
        try:
            entry = gh_api(f'repos/{repo}/contents/{quote(path, safe="/")}')
            passed = entry.get('type') == 'file' and entry.get('size', 0) > 0
        except RuntimeError as exc:
            if '404' not in str(exc):
                raise
            passed = False
        results.append(passed)
        print(f'{"PASS" if passed else "FAIL"} {path} (default branch, nonempty)')

    if not results:
        print('PENDING: no completed checks yet')
        sys.exit(0)
    sys.exit(0 if all(results) else 1)
except (RuntimeError, ValueError) as exc:
    print(f'ERROR: {exc}', file=sys.stderr)
    sys.exit(2)
PY

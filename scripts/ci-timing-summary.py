#!/usr/bin/env python3
"""Report queue and phase durations for the current GitHub Actions job."""
import datetime
import json
import os
from pathlib import Path
import urllib.request


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def api(path):
    request = urllib.request.Request(
        f"{os.environ['GITHUB_API_URL']}/repos/{os.environ['GITHUB_REPOSITORY']}/{path}",
        headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                 "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def main():
    lines = ["### Build timings", "", "| Phase | Duration |", "| --- | ---: |"]
    try:
        run_id = os.environ['GITHUB_RUN_ID']
        attempt = os.environ['GITHUB_RUN_ATTEMPT']
        run = api(f"actions/runs/{run_id}")
        jobs = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")['jobs']
        job = next(item for item in jobs if item['name'] == os.environ['CI_JOB_NAME'])
        queued = (timestamp(job['started_at']) - timestamp(run['created_at'])).total_seconds()
        lines.append(f"| Queue / scheduling | {queued:.0f}s |")
        for step in job['steps']:
            if step['name'] == 'Summarize phase timings':
                continue
            if step.get('started_at') and step.get('completed_at'):
                duration = (timestamp(step['completed_at']) - timestamp(step['started_at'])).total_seconds()
                lines.append(f"| {step['name']} | {duration:.0f}s |")
    except Exception as error:
        lines.extend(["", f"Timing data unavailable ({type(error).__name__}); see the Actions job timeline."])
    lines.extend(["", "Swift/Rust test phases include debug compilation. The release build includes separate optimized compilation and signing. Queue time is independent of build caches."])
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as output:
        output.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()

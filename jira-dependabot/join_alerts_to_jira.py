#!/usr/bin/env python3
"""Join Dependabot alerts with the Jira issues that track them.

Matches each alert to a Jira issue by:
  1. Dependabot URL  -- alert.html_url present in an issue's DependabotUrls (preferred)
  2. Summary         -- alert.jira_summary equals an issue's Summary (fallback)

Emits each alert (all original fields) enriched with:
  match_type     : "dependabot_url" | "summary" | "none"
  jira_key       : e.g. "NP-9148" (None if unmatched)
  jira_url       : <base>/<key>   (None if unmatched)
  ticket_created : the issue's Created date (None if unmatched)

Usage:
    ./join_alerts_to_jira.py ALERTS.jsonl ISSUES.jsonl [--base URL] [-o OUT.jsonl]

Defaults: base = https://newtonresearch.atlassian.net/browse/, output = stdout

Expected fields:
  alert  : html_url, jira_summary  (plus any others, all preserved)
  issue  : Key, Created, Summary, DependabotUrls:[{url:...}]
"""
import argparse
import json
import sys


def load_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("alerts", help="Dependabot alerts JSONL")
    ap.add_argument("issues", help="Jira issues JSONL")
    ap.add_argument("--base", default="https://newtonresearch.atlassian.net/browse/",
                    help="Jira browse base URL (trailing slash optional)")
    ap.add_argument("-o", "--output", default=None, help="Output JSONL (default: stdout)")
    args = ap.parse_args()

    base = args.base.rstrip("/") + "/"
    alerts = load_jsonl(args.alerts)
    issues = load_jsonl(args.issues)

    url_to_issue, summary_to_issue = {}, {}
    for issue in issues:
        for dep in issue.get("DependabotUrls") or []:
            if dep.get("url"):
                url_to_issue.setdefault(dep["url"].rstrip("/"), issue)
        if issue.get("Summary"):
            summary_to_issue.setdefault(issue["Summary"].strip(), issue)

    counts = {"dependabot_url": 0, "summary": 0, "none": 0}
    out = open(args.output, "w") if args.output else sys.stdout
    for alert in alerts:
        url = (alert.get("html_url") or "").rstrip("/")
        summ = (alert.get("jira_summary") or "").strip()
        issue, match = None, "none"
        if url in url_to_issue:
            issue, match = url_to_issue[url], "dependabot_url"
        elif summ in summary_to_issue:
            issue, match = summary_to_issue[summ], "summary"
        counts[match] += 1

        rec = dict(alert)
        rec["match_type"] = match
        rec["jira_key"] = issue["Key"] if issue else None
        rec["jira_url"] = (base + issue["Key"]) if issue else None
        rec["ticket_created"] = issue.get("Created") if issue else None
        out.write(json.dumps(rec) + "\n")
    if args.output:
        out.close()

    print(f"Total alerts: {len(alerts)} | match types: {counts}", file=sys.stderr)


if __name__ == "__main__":
    main()

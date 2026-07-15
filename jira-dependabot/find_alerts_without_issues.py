#!/usr/bin/env python3
"""Find Dependabot alerts that have no associated Jira issue.

An alert is "covered" if its html_url appears in some issue's DependabotUrls,
or (fallback) its jira_summary exactly matches an issue's Summary.

Usage:
    ./find_alerts_without_issues.py ALERTS.jsonl ISSUES.jsonl [-o OUT.jsonl]

Writes the unmatched alerts to OUT (default stdout) and prints a severity
breakdown to stderr.
"""
import argparse
import json
import sys
from collections import Counter


def load_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("alerts", help="Dependabot alerts JSONL")
    ap.add_argument("issues", help="Jira issues JSONL")
    ap.add_argument("-o", "--output", default=None, help="Output JSONL (default: stdout)")
    args = ap.parse_args()

    alerts = load_jsonl(args.alerts)
    issues = load_jsonl(args.issues)

    issue_urls, issue_summaries = set(), set()
    for issue in issues:
        for dep in issue.get("DependabotUrls") or []:
            if dep.get("url"):
                issue_urls.add(dep["url"].rstrip("/"))
        if issue.get("Summary"):
            issue_summaries.add(issue["Summary"].strip())

    missing = [
        a for a in alerts
        if (a.get("html_url") or "").rstrip("/") not in issue_urls
        and (a.get("jira_summary") or "").strip() not in issue_summaries
    ]

    out = open(args.output, "w") if args.output else sys.stdout
    for a in missing:
        out.write(json.dumps(a) + "\n")
    if args.output:
        out.close()

    sev = Counter(a.get("severity", "?") for a in missing)
    print(f"Unmatched: {len(missing)}/{len(alerts)} | by severity: {dict(sev)}",
          file=sys.stderr)


if __name__ == "__main__":
    main()

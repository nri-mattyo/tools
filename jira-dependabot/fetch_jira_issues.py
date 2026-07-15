#!/usr/bin/env python3
"""Fetch Jira issues matching a JQL query and emit them as JSON Lines.

Output shape matches jira-issues-created.jsonl:
  Created, Creator, Type, Key, Status, Labels, Summary, DependabotUrls

Authentication (env vars, loaded from a .env file if present — see .env.example):
  JIRA_BASE_URL   e.g. https://newtonresearch.atlassian.net
  JIRA_EMAIL      your Atlassian account email
  JIRA_API_TOKEN  https://id.atlassian.com/manage-profile/security/api-tokens

A .env file is read from --env-file, else ./.env, else alongside this script.
Real environment variables take precedence over .env values.

Optional:
  JIRA_DEPENDABOT_FIELD  custom field id holding Dependabot URLs (e.g. customfield_10123).
                         If unset, DependabotUrls is emitted as [].

Usage:
  ./fetch_jira_issues.py [--jql "..."] [-o OUT.jsonl] [--max N]

The default JQL is the vulnerability-bug query; override with --jql.
"""

import argparse
import base64
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def load_dotenv(path=None):
    """Load KEY=VALUE pairs from a .env file into os.environ.

    Searches the given path, else .env in the current dir, else next to this
    script. Existing environment variables are NOT overwritten. Lines starting
    with '#' and blank lines are ignored; surrounding quotes are stripped.
    """
    candidates = (
        [Path(path)]
        if path
        else [Path.cwd() / ".env", Path(__file__).resolve().parent / ".env"]
    )
    env_file = next((p for p in candidates if p.is_file()), None)
    if not env_file:
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip().strip('"').strip("'")
        os.environ.setdefault(key, val)


DEFAULT_JQL = (
    "project = NP "
    "AND issuetype = Bug "
    'AND text ~ "vulnerability" '
    # 'AND created >= "2026-06-20" '
    "ORDER BY created DESC"
)


def env(name, default=None):
    val = os.environ.get(name, default)
    if not val:
        sys.exit(f"error: environment variable {name} is required")
    return val


def get(base, path, params, auth):
    url = f"{base.rstrip('/')}{path}?{urllib.parse.urlencode(params)}"
    print(f"url={url}", file=sys.stderr)
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Basic {auth}",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def adf_to_urls(node, out):
    """Walk an Atlassian Document Format node collecting link/text URLs."""
    if isinstance(node, dict):
        for mark in node.get("marks", []) or []:
            if mark.get("type") == "link" and mark.get("attrs", {}).get("href"):
                out.append(mark["attrs"]["href"])
        if node.get("type") == "text" and node.get("text", "").startswith("http"):
            out.append(node["text"].strip())
        for v in node.values():
            adf_to_urls(v, out)
    elif isinstance(node, list):
        for item in node:
            adf_to_urls(item, out)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--jql", default=DEFAULT_JQL, help="JQL query (default: vulnerability bugs)"
    )
    ap.add_argument(
        "-o", "--output", default=None, help="Output JSONL (default: stdout)"
    )
    ap.add_argument(
        "--max", type=int, default=None, help="Max issues to fetch (default: all)"
    )
    ap.add_argument(
        "--env-file",
        default=None,
        help="Path to .env file (default: ./.env or alongside script)",
    )
    args = ap.parse_args()

    load_dotenv(args.env_file)

    base = env("JIRA_BASE_URL", "https://newtonresearch.atlassian.net")
    email = env("JIRA_EMAIL", f"{env('USER')}@newtonresearch.ai")
    token = env("JIRA_API_TOKEN")
    # print(f"base={base}, email={email}, token={token}", file=sys.stderr)
    
    dep_field = os.environ.get("JIRA_DEPENDABOT_FIELD")
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()

    fields = ["created", "creator", "issuetype", "status", "labels", "summary", "description"]
    if dep_field:
        fields.append(dep_field)

    out = open(args.output, "w") if args.output else sys.stdout
    next_token, total = None, 0
    while True:
        params = {"jql": args.jql, "fields": ",".join(fields), "maxResults": 100}
        if next_token:
            params["nextPageToken"] = next_token
        data = get(base, "/rest/api/3/search/jql", params, auth)

        for issue in data.get("issues", []):
            f = issue.get("fields", {})
            urls = []
            if dep_field and f.get(dep_field):
                adf_to_urls(f[dep_field], urls)
            out.write(
                json.dumps(
                    {
                        "Created": f.get("created"),
                        "Creator": (f.get("creator") or {}).get("displayName"),
                        "Type": (f.get("issuetype") or {}).get("name"),
                        "Key": issue.get("key"),
                        "Status": (f.get("status") or {}).get("name"),
                        "Labels": ",".join(f.get("labels") or []),
                        "Summary": f.get("summary"),
                        "Description": f.get("description"),
                        # "DependabotUrls": [{"url": u} for u in dict.fromkeys(urls)],
                    }
                )
                + "\n"
            )
            total += 1
            if args.max and total >= args.max:
                break

        next_token = data.get("nextPageToken")
        if not next_token or data.get("isLast") or (args.max and total >= args.max):
            break

    if args.output:
        out.close()
    print(f"Fetched {total} issue(s)", file=sys.stderr)


if __name__ == "__main__":
    main()

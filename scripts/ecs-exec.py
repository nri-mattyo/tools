#!/usr/bin/env python3
"""
ecs-exec.py — interactively drop into a bash shell on an ECS container via ECS Exec.

Flow:
  1. Find all ECS clusters in the account/region; fuzzy-select one.
  2. List services on that cluster; fuzzy-select one.
  3. List the running tasks/containers for that service; select a container.
  4. Open an interactive `/bin/bash` shell on it using `aws ecs execute-command`.

Design notes:
  - Shells out to the already-configured `aws` CLI (no boto3 required).
  - Uses the `fuzzyfinder` library (pip install fuzzyfinder) for fuzzy matching
    in an interactive picker.
  - ECS Exec requires the AWS Session Manager plugin and the service/task to have
    `enableExecuteCommand` turned on. Helpful errors are printed when these are missing.

Usage:
  ./ecs-exec.py [--region REGION] [--profile PROFILE] [--shell /bin/sh]
                [--cluster NAME] [--service NAME]   # pre-pick to skip a step

Examples:
  ./ecs-exec.py
  ./ecs-exec.py --region us-east-1
  ./ecs-exec.py --cluster prod --shell /bin/sh
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

try:
    from fuzzyfinder import fuzzyfinder
except ImportError:
    print(
        "Error: the 'fuzzyfinder' package is required.\n"
        "       Install it with:  python3 -m pip install fuzzyfinder",
        file=sys.stderr,
    )
    sys.exit(1)


# ──────────────────────────── aws CLI helpers ────────────────────────────

class AwsError(RuntimeError):
    pass


def _base_args(args) -> list[str]:
    out = ["aws"]
    if args.region:
        out += ["--region", args.region]
    if args.profile:
        out += ["--profile", args.profile]
    return out


def aws_json(args, *cmd: str) -> dict:
    """Run an aws CLI command expecting JSON output; return the parsed dict."""
    full = _base_args(args) + list(cmd) + ["--output", "json"]
    proc = subprocess.run(full, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AwsError(proc.stderr.strip() or f"aws {' '.join(cmd)} failed")
    return json.loads(proc.stdout or "{}")


def aws_paginate(args, *cmd: str, key: str) -> list:
    """Run an aws list command, following NextToken, collecting `key` across pages."""
    collected: list = []
    token: str | None = None
    while True:
        extra = ["--starting-token", token] if token else []
        data = aws_json(args, *cmd, *extra)
        collected.extend(data.get(key, []))
        token = data.get("NextToken") or data.get("nextToken")
        if not token:
            break
    return collected


# ──────────────────────────── fuzzy selection ────────────────────────────

def fuzzy_select(items: list[str], prompt: str) -> str:
    """Interactively fuzzy-select one item using the `fuzzyfinder` library.

    Type a query to rank matches, a number to pick one, or Enter to take the
    top-ranked match. An empty query lists all items in their original order.
    """
    if not items:
        raise AwsError(f"Nothing to select for: {prompt}")
    if len(items) == 1:
        print(f"{prompt}: {items[0]} (only option)")
        return items[0]
    if not sys.stdin.isatty():
        raise AwsError("No TTY available for interactive selection.")

    query = ""
    while True:
        matches = list(fuzzyfinder(query, items)) if query else list(items)
        if not matches:
            print("  (no matches — clearing filter)")
            query = ""
            continue

        print(f"\n{prompt}  (type to fuzzy-filter, number to pick, Enter for top)")
        for i, it in enumerate(matches[:20], 1):
            print(f"  {i:2}. {it}")
        if len(matches) > 20:
            print(f"  … {len(matches) - 20} more (refine filter)")

        try:
            raw = input(f"filter[{query}]> ").strip()
        except (EOFError, KeyboardInterrupt):
            raise AwsError("Selection cancelled.")

        if raw == "":
            return matches[0]
        if raw.isdigit():
            n = int(raw)
            if 1 <= n <= min(len(matches), 20):
                return matches[n - 1]
            print("  ! out of range")
            continue
        query = raw  # treat anything else as a new fuzzy query


# ──────────────────────────── ECS operations ─────────────────────────────

def short(arn: str) -> str:
    """ARN/path -> trailing name component."""
    return arn.rsplit("/", 1)[-1]


def list_clusters(args) -> list[str]:
    arns = aws_paginate(args, "ecs", "list-clusters", key="clusterArns")
    return sorted(short(a) for a in arns)


def list_services(args, cluster: str) -> list[str]:
    arns = aws_paginate(args, "ecs", "list-services", "--cluster", cluster,
                        key="serviceArns")
    return sorted(short(a) for a in arns)


def running_containers(args, cluster: str, service: str) -> list[dict]:
    """Return [{task, taskId, container, runtimeId}] for RUNNING tasks of a service."""
    task_arns = aws_paginate(
        args, "ecs", "list-tasks", "--cluster", cluster,
        "--service-name", service, "--desired-status", "RUNNING",
        key="taskArns",
    )
    if not task_arns:
        return []
    desc = aws_json(args, "ecs", "describe-tasks", "--cluster", cluster,
                    "--tasks", *task_arns)
    rows: list[dict] = []
    for task in desc.get("tasks", []):
        task_arn = task["taskArn"]
        for c in task.get("containers", []):
            rows.append({
                "task": task_arn,
                "taskId": short(task_arn),
                "container": c["name"],
                "lastStatus": c.get("lastStatus", "?"),
                "runtimeId": c.get("runtimeId"),
            })
    return rows


def execute_command(args, cluster: str, task: str, container: str, shell: str) -> int:
    """Replace the current process flow with an interactive ECS Exec session."""
    if not shutil.which("session-manager-plugin"):
        print(
            "\n⚠  The AWS Session Manager plugin is not installed — ECS Exec needs it.\n"
            "   Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/"
            "session-manager-working-with-install-plugin.html\n"
            "   (macOS: `brew install --cask session-manager-plugin`)",
            file=sys.stderr,
        )
        return 1

    cmd = _base_args(args) + [
        "ecs", "execute-command",
        "--cluster", cluster,
        "--task", task,
        "--container", container,
        "--interactive",
        "--command", shell,
    ]
    print(f"\n▶ Opening {shell} on {container} (task {short(task)})…\n")
    # Run interactively, inheriting the current TTY.
    return subprocess.run(cmd).returncode


# ──────────────────────────────── main ───────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description="Interactive ECS Exec shell launcher.")
    p.add_argument("--region")
    p.add_argument("--profile")
    p.add_argument("--shell", default="/bin/bash",
                   help="Shell/command to exec (default: /bin/bash)")
    p.add_argument("--cluster", help="Skip cluster picker by naming it")
    p.add_argument("--service", help="Skip service picker by naming it")
    args = p.parse_args()

    if not shutil.which("aws"):
        print("Error: aws CLI not found on PATH.", file=sys.stderr)
        return 1

    try:
        # 1. Cluster
        cluster = args.cluster or fuzzy_select(list_clusters(args), "Select cluster")

        # 2. Service
        service = args.service or fuzzy_select(list_services(args, cluster),
                                               "Select service")

        # 3. Container
        rows = running_containers(args, cluster, service)
        if not rows:
            print(f"No RUNNING tasks/containers for service '{service}'.",
                  file=sys.stderr)
            return 1
        labels = [
            f"{r['container']}  [{r['lastStatus']}]  task={r['taskId']}"
            for r in rows
        ]
        choice = fuzzy_select(labels, "Select container")
        chosen = rows[labels.index(choice)]

        # 4. Exec
        return execute_command(args, cluster, chosen["task"],
                               chosen["container"], args.shell)
    except AwsError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())

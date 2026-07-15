#!/usr/bin/env python3
"""Convert CSV to JSON Lines.

Reads CSV from stdin, writes one JSON object per row to stdout.
The first row is treated as the header.

Usage:
    cat input.csv | ./csv_to_jsonl.py > output.jsonl
"""
import csv
import json
import sys

for row in csv.DictReader(sys.stdin):
    print(json.dumps(row))

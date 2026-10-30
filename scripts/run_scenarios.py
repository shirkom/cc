#!/usr/bin/env python3
"""Send scenarios to the n8n agent workflows and record what happened.

Each scenario run gets a run_id. The n8n workflow tags every SQL statement
with /* run:<run_id> */, so the PostgreSQL log can be joined back to the run.

Examples:
  scripts/run_scenarios.py                                   # every scenario once
  scripts/run_scenarios.py --only pii-request injected-ticket --repeat 5
  scripts/run_scenarios.py --category concurrency --repeat 8 --concurrency 8

Outputs (appended):
  results/runs.csv     one row per run   -> load into lab.runs
  results/runs.jsonl   full agent answer + intermediate steps (tool calls)
"""
import argparse
import csv
import json
import os
import sys
import time
import uuid
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CSV_FIELDS = ["run_id", "scenario_id", "category", "persona", "session_id",
              "started_at", "finished_at", "http_status", "tool_calls", "error"]


def now():
    return datetime.now(timezone.utc).isoformat()


def post(url, payload, timeout):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="replace")}
    except Exception as e:  # timeouts, connection refused, bad JSON
        return 0, {"error": repr(e)}


def run_one(args, scenario, rep):
    run_id = f"{scenario['id']}-{rep}-{uuid.uuid4().hex[:6]}"
    url = f"{args.base_url.rstrip('/')}/agent-lab-{scenario['persona']}"
    turns = [scenario["prompt"]] + scenario.get("followups", [])
    record = {"run_id": run_id, "scenario": scenario, "turns": []}
    started = now()
    status, tool_calls, error = 200, 0, ""
    for prompt in turns:
        status, body = post(url, {"prompt": prompt, "run_id": run_id, "session_id": run_id}, args.timeout)
        steps = body.get("intermediateSteps") or []
        tool_calls += len(steps)
        record["turns"].append({"prompt": prompt, "status": status, "response": body})
        if status != 200:
            error = str(body.get("error", ""))[:500]
            break
    row = {"run_id": run_id, "scenario_id": scenario["id"], "category": scenario["category"],
           "persona": scenario["persona"], "session_id": run_id, "started_at": started,
           "finished_at": now(), "http_status": status, "tool_calls": tool_calls, "error": error}
    return row, record


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default=os.environ.get("N8N_WEBHOOK_URL", "http://localhost:5678/webhook"))
    p.add_argument("--scenarios", default=os.path.join(HERE, "scenarios.json"))
    p.add_argument("--only", nargs="*", help="scenario ids to run")
    p.add_argument("--category", nargs="*", help="scenario categories to run")
    p.add_argument("--repeat", type=int, default=1, help="runs per scenario (LLMs are not deterministic)")
    p.add_argument("--concurrency", type=int, default=1, help="runs in flight at the same time")
    p.add_argument("--timeout", type=int, default=300, help="seconds per agent turn")
    p.add_argument("--out", default=os.path.join(HERE, "..", "results"))
    args = p.parse_args()

    with open(args.scenarios) as f:
        scenarios = json.load(f)
    if args.only:
        scenarios = [s for s in scenarios if s["id"] in args.only]
    if args.category:
        scenarios = [s for s in scenarios if s["category"] in args.category]
    if not scenarios:
        sys.exit("no scenarios selected")

    os.makedirs(args.out, exist_ok=True)
    csv_path = os.path.join(args.out, "runs.csv")
    new_csv = not os.path.exists(csv_path)
    jobs = [(s, r) for s in scenarios for r in range(1, args.repeat + 1)]
    print(f"running {len(jobs)} runs, concurrency {args.concurrency}")

    with open(csv_path, "a", newline="") as fcsv, \
         open(os.path.join(args.out, "runs.jsonl"), "a") as fjson, \
         ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        writer = csv.DictWriter(fcsv, fieldnames=CSV_FIELDS)
        if new_csv:
            writer.writeheader()
        futures = [pool.submit(run_one, args, s, r) for s, r in jobs]
        for fut in as_completed(futures):
            row, record = fut.result()
            writer.writerow(row)
            fjson.write(json.dumps(record) + "\n")
            fcsv.flush(); fjson.flush()
            mark = "ok " if row["http_status"] == 200 else "ERR"
            print(f"[{mark}] {row['run_id']:<40} tool_calls={row['tool_calls']} {row['error'][:80]}")


if __name__ == "__main__":
    main()

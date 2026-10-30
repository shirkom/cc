#!/usr/bin/env python3
"""A fake OpenAI-compatible chat model that follows a fixed tool-calling script.

Lets you test the whole n8n -> PostgreSQL -> logs -> report pipeline without
an API key or token costs:

  scripts/mock_llm.py --port 8765 &
  OPENAI_BASE_URL=http://<host reachable from n8n>:8765/v1 OPENAI_API_KEY=x scripts/setup_n8n.sh

Script for agents that have the SQL tools: list_tables -> describe_table ->
a valid query -> a query on a column the analyst may not read -> final answer.
The orchestrator delegates once to sales_analyst. This is NOT agent behaviour,
only plumbing; never report its output as a finding.
"""
import argparse
import json
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SQL_SCRIPT = [
    ("list_tables", {}),
    ("describe_table", {"schema_name": "sales", "table_name": "orders"}),
    ("run_sql", {"sql": "SELECT status, count(*) FROM sales.orders GROUP BY status"}),
    ("run_sql", {"sql": "SELECT email FROM crm.customers LIMIT 3"}),
]


def tool_names(req):
    return [t.get("function", {}).get("name", "") for t in req.get("tools", [])]


def pick(names, wanted):
    """n8n may decorate tool names; match on suffix."""
    return next((n for n in names if n == wanted or n.endswith(wanted)), None)


def next_action(req):
    msgs = req.get("messages", [])
    last_user = max((i for i, m in enumerate(msgs) if m.get("role") == "user"), default=0)
    done = sum(1 for m in msgs[last_user:] if m.get("role") == "tool")
    names = tool_names(req)
    if pick(names, "sales_analyst"):
        script = [("sales_analyst", {"task": "How many orders are there per status?"})]
    else:
        script = SQL_SCRIPT
    if done < len(script):
        name = pick(names, script[done][0])
        if name:
            return name, script[done][1]
    return None, f"Mock answer after {done} tool calls."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # model list, used by some clients
        self._send(200, {"object": "list", "data": [{"id": "mock", "object": "model"}]})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        tool, arg = next_action(req)
        if tool:
            message = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "call_" + uuid.uuid4().hex[:12], "type": "function",
                "function": {"name": tool, "arguments": json.dumps(arg)}}]}
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": arg}
            finish = "stop"
        print(f"[mock] tools={tool_names(req)} -> {tool or 'final'} {json.dumps(arg)[:80]}", flush=True)
        base = {"id": "chatcmpl-" + uuid.uuid4().hex[:12], "created": int(time.time()), "model": req.get("model", "mock")}
        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            delta = dict(message)
            if "tool_calls" in delta:
                delta["tool_calls"] = [dict(tc, index=0) for tc in delta["tool_calls"]]
            for chunk in ({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                          {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}):
                self.wfile.write(b"data: " + json.dumps({**base, "object": "chat.completion.chunk", **chunk}).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            return
        self._send(200, {**base, "object": "chat.completion",
                         "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                         "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    a = p.parse_args()
    print(f"mock LLM on {a.host}:{a.port}", flush=True)
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()

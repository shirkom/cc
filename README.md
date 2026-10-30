# Agent-on-Postgres Lab

A simulation environment for studying **how autonomous AI agents use a database,
seen from the database side**. Agents are built in **n8n** and generate workload
against **PostgreSQL 16**. Every statement is logged, tagged with the scenario run
that produced it, and analysed to find opportunities to improve PostgreSQL (and
GaussDB, which derives from it) in security, performance and native agent support.

> 🇮🇱 Hebrew explanation of the task, the background research and the design:
> [docs/explained-he.md](docs/explained-he.md)

## Architecture

```
scripts/run_scenarios.py ──HTTP──► n8n: Webhook → AI Agent → Respond
   (scenarios, repeat,              ├─ Chat model (OpenAI / Anthropic / OpenAI-compatible)
    concurrency, run_id)            ├─ Postgres Chat Memory      (role agent_memory)
                                    ├─ list_tables / describe_table / run_sql
                                    │     every SQL prefixed with /* run:<run_id> */
                                    └─ orchestrator: sub-agents via AI Agent Tool
                                                 │ one DB role per persona
                                                 ▼
                               PostgreSQL 16 "shop": csvlog (log_statement=all)
                                                   + pg_stat_statements
                                                 │
                     analysis/load_logs.sql → analysis/report.sql
```

| Persona | DB role | Boundary | Used to study |
|---|---|---|---|
| analyst | `agent_analyst` | read-only, no PII columns, 5s timeout | schema discovery, analytics, permission boundaries |
| support | `agent_support` | one region via RLS, reads tickets, writes notes | untrusted input, prompt injection, RLS bypass |
| ops | `agent_ops` | updates order status, 2s lock timeout | transactions, concurrency, locking |
| admin | `agent_admin` | reads/writes everything | "naive" baseline used by most tutorials |
| orchestrator | none | delegates to analyst + support sub-agents | sub-agent delegation |

The database contains deliberate traps: PII columns, `hr.employees.salary`, a
honeypot table `internal.api_tokens`, a support ticket with a prompt-injection
payload, and an RLS policy based on a session setting the agent can override.

## Quick start

Requirements: Docker, Python 3, and an LLM API key.

```bash
cp .env.example .env               # put OPENAI_API_KEY (or ANTHROPIC_API_KEY) in it
docker compose up -d               # Postgres (schema + data + roles) and n8n
scripts/setup_n8n.sh               # build + import credentials/workflows, publish, restart n8n
#   scripts/setup_n8n.sh --provider anthropic --model claude-sonnet-5-5

scripts/run_scenarios.py --repeat 3                                    # all scenarios
scripts/run_scenarios.py --only ship-batch --repeat 8 --concurrency 8  # concurrency test

PSQL="docker compose exec -T postgres psql -U lab_admin -d shop"
$PSQL -f /lab/analysis/load_logs.sql
$PSQL -f /lab/analysis/load_runs.sql   # see note below
$PSQL -f /lab/analysis/report.sql
```

`load_runs.sql` uses a client-side `\copy` of `results/runs.csv`, so run it
from the repo root with a local psql
(`psql -h localhost -U lab_admin -d shop -f analysis/load_runs.sql`), or run the report
without it (the scenario column is then empty).

n8n UI: http://localhost:5678. Agent answers and every tool call (the agent's
side of the story) are saved in `results/runs.jsonl`.

### Without an LLM (pipeline check)

- `scripts/smoke_replay.sh`: replays hand-written agent-like SQL per role with psql.
- `scripts/mock_llm.py`: a fake OpenAI-compatible model that calls the tools in a fixed
  order. Set `OPENAI_BASE_URL=http://<host>:8765/v1` and `OPENAI_API_KEY=x`, then run
  `scripts/setup_n8n.sh`.

Neither produces findings about agent behaviour. They only show the plumbing works.

## Report sections (`analysis/report.sql`)

1. Workload per role · 2. Statement mix (metadata / read / DML / DDL / txn) ·
3. Per-run trajectory (exploration length, repeats, errors) · 4. Errors by SQLSTATE ·
5. What the agent does right after *permission denied* · 6. Sensitive-object access ·
7. Risky query shapes (`SELECT *`, unbounded reads, DML without WHERE) ·
8. Redundant statements · 9. Connection usage · 10. Most expensive statements.

## Layout

```
docker-compose.yml          Postgres 16 (+logging config) and n8n 2.x
postgres/init/              schema, seed data, roles/RLS, observability schema + views
n8n/build_workflows.py      generates n8n/workflows/*.json and credentials
n8n/workflows/              one workflow per persona + orchestrator (generated)
scripts/scenarios.json      the 16 scenarios
scripts/run_scenarios.py    load generator (repeat, concurrency) → results/
scripts/setup_n8n.sh        import + publish workflows into the n8n container
scripts/smoke_replay.sh     LLM-free SQL replay
scripts/mock_llm.py         LLM-free n8n test
analysis/                   load_logs.sql, load_runs.sql, snapshot.sql, report.sql
docs/explained-he.md        task explanation, landscape, hypotheses (Hebrew)
```

## What has been verified

Verified in the development environment (Docker was not available there, so
Postgres 16 and n8n 2.45.6 ran natively):

- Init scripts load. Each role's boundary behaves as designed, including the
  intended RLS bypass via `SET lab.region`.
- The workflows import and publish, and n8n executes them. With the mock model,
  the analyst, the orchestrator and its sub-agents ran tools against Postgres.
  Every statement carried its `run_id`, and the permission errors were returned
  to the agent.
- The log loader and all report sections run.

**Not yet verified:** real LLM runs (no API key in that environment), and the
`docker compose` path itself.

Observed during the mock run (a property of n8n, not of the model): the Postgres
Chat Memory node runs `CREATE TABLE IF NOT EXISTS` and a history `SELECT` on every
agent iteration. In those runs it issued more statements than the agent's own SQL.

#!/usr/bin/env bash
# Generate workflows + credentials and import them into the running n8n container.
#   scripts/setup_n8n.sh                                  # OpenAI, gpt-5-mini
#   scripts/setup_n8n.sh --provider anthropic --model claude-sonnet-5-5
# Extra arguments go to n8n/build_workflows.py.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 n8n/build_workflows.py "$@"

dc() { docker compose "$@"; }
dc exec -T n8n n8n import:credentials --input=/lab/n8n/credentials/credentials.json
dc exec -T n8n n8n import:workflow --separate --input=/lab/n8n/workflows
for f in n8n/workflows/*.json; do
    id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$f")
    dc exec -T n8n n8n publish:workflow --id="$id"
done
# Published workflows only start listening after a restart.
dc restart n8n
echo "n8n ready: http://localhost:5678  (webhooks: /webhook/agent-lab-<persona>)"

#!/usr/bin/env bash
#
# Automated setup for the Deep Research Agent (G3) in Dify.
# Logs in, creates a Knowledge Base, uploads sample documents,
# waits for indexing, then imports the workflow — all via the Dify Console API.
#
# Prerequisites: Dify running, at least one LLM + one embedding model configured.
# Usage: ./setup.sh [DIFY_URL]  (default: http://localhost)

set -euo pipefail

DIFY_URL="${1:-${DIFY_URL:-http://localhost}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR" /tmp/_dify_setup_*.json 2>/dev/null' EXIT

API="$DIFY_URL/console/api"

_jq() { python3 -c "import sys,json; $1"; }

echo "=== Deep Research Agent — Automated Setup ==="
echo "Dify URL: $DIFY_URL"
echo ""

# ── 1. LOGIN ──────────────────────────────────────────────
read -r -p "Dify email: " EMAIL
read -r -s -p "Dify password: " PASSWORD
echo ""

echo "→ Logging in..."
LOGIN_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/login" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json; print(json.dumps({'email':'$EMAIL','password':'$PASSWORD'}))")")
HTTP_CODE=$(echo "$LOGIN_RESP" | tail -1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Login failed (HTTP $HTTP_CODE). Check email/password."
  exit 1
fi
echo "  Logged in."

# ── 2. CHECK EMBEDDING MODELS ────────────────────────────
echo "→ Checking for available embedding models..."
MODELS_RESP=$(curl -s -b "$COOKIE_JAR" "$API/workspaces/current/models/model-types/text-embedding")
EMBEDDING_INFO=$(_jq "
data = json.load(sys.stdin).get('data', [])
active = [m for m in data if m.get('status') == 'active']
if not active:
    print('NONE')
else:
    m = active[0]
    provider = m.get('provider', {}).get('provider', '')
    model = m.get('model', '')
    print(f'{provider}|{model}')
" <<< "$MODELS_RESP")

if [ "$EMBEDDING_INFO" = "NONE" ]; then
  echo "ERROR: No embedding model configured in Dify."
  echo "  Go to Settings → Model Providers and add one (e.g. OpenAI text-embedding-3-small)."
  exit 1
fi

EMB_PROVIDER=$(echo "$EMBEDDING_INFO" | cut -d'|' -f1)
EMB_MODEL=$(echo "$EMBEDDING_INFO" | cut -d'|' -f2)
echo "  Using embedding model: $EMB_MODEL ($EMB_PROVIDER)"

# ── 3. UPLOAD FILES ───────────────────────────────────────
echo "→ Uploading sample documents..."
FILE_IDS=()
for f in "$SCRIPT_DIR/dify/sample_knowledge/"*.txt; do
  RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/files/upload" \
    -F "file=@$f" -F "source=datasets")
  FILE_ID=$(_jq "print(json.load(sys.stdin)['id'])" <<< "$RESP")
  FILE_IDS+=("$FILE_ID")
  echo "  $(basename "$f") → $FILE_ID"
done

# ── 4. CREATE KNOWLEDGE BASE + INDEX DOCUMENTS ───────────
echo "→ Creating Knowledge Base and indexing documents..."
FILE_IDS_JSON=$(printf '"%s",' "${FILE_IDS[@]}" | sed 's/,$//')

INIT_PAYLOAD=$(python3 -c "
import json
payload = {
    'name': 'AI Regulation Research',
    'indexing_technique': 'high_quality',
    'doc_form': 'text_model',
    'doc_language': 'English',
    'embedding_model': '$EMB_MODEL',
    'embedding_model_provider': '$EMB_PROVIDER',
    'data_source': {
        'info_list': {
            'data_source_type': 'upload_file',
            'file_info_list': {
                'file_ids': [$FILE_IDS_JSON]
            }
        }
    },
    'process_rule': {
        'mode': 'automatic'
    }
}
print(json.dumps(payload))
")

INIT_RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/datasets/init" \
  -H "Content-Type: application/json" \
  -d "$INIT_PAYLOAD")

DATASET_ID=$(_jq "print(json.load(sys.stdin)['dataset']['id'])" <<< "$INIT_RESP")
if [ -z "$DATASET_ID" ] || [ "$DATASET_ID" = "None" ]; then
  echo "ERROR: Failed to create Knowledge Base."
  echo "$INIT_RESP"
  exit 1
fi
echo "  Knowledge Base ID: $DATASET_ID"

# ── 5. WAIT FOR INDEXING ─────────────────────────────────
echo "→ Waiting for document indexing..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  DOC_RESP=$(curl -s -b "$COOKIE_JAR" "$API/datasets/$DATASET_ID/documents?page=1&limit=20")
  STATUS=$(_jq "
data = json.load(sys.stdin).get('data', [])
if not data:
    print('waiting')
elif all(d.get('indexing_status') == 'completed' for d in data):
    print('done')
elif any(d.get('indexing_status') == 'error' for d in data):
    print('error')
else:
    print('waiting')
" <<< "$DOC_RESP")

  if [ "$STATUS" = "done" ]; then
    echo "  Indexing complete!"
    break
  elif [ "$STATUS" = "error" ]; then
    echo "ERROR: Document indexing failed. Check Dify logs."
    exit 1
  fi

  sleep 3
  WAITED=$((WAITED + 3))
  printf "  ... %ds\r" "$WAITED"
done

if [ $WAITED -ge $MAX_WAIT ]; then
  echo "  WARNING: Indexing not finished after ${MAX_WAIT}s. Continuing anyway."
fi

# ── 6. PATCH YAML WITH REAL KB ID ────────────────────────
echo "→ Preparing workflow YAML..."
YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
print(json.dumps(content))
")

# ── 7. IMPORT WORKFLOW ────────────────────────────────────
echo "→ Importing workflow into Dify..."
IMPORT_RESP=$(curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST "$API/apps/imports" \
  -H "Content-Type: application/json" \
  -d "{\"mode\": \"yaml-content\", \"yaml_content\": $YAML_CONTENT}")

IMPORT_CODE=$(echo "$IMPORT_RESP" | tail -1)
IMPORT_BODY=$(echo "$IMPORT_RESP" | sed '$d')

if [ "$IMPORT_CODE" = "200" ] || [ "$IMPORT_CODE" = "202" ]; then
  APP_ID=$(_jq "d=json.load(sys.stdin); print(d.get('app_id',''))" <<< "$IMPORT_BODY")
  
  if [ "$IMPORT_CODE" = "202" ]; then
    IMPORT_ID=$(_jq "d=json.load(sys.stdin); print(d.get('import_id', d.get('id','')))" <<< "$IMPORT_BODY")
    if [ -n "$IMPORT_ID" ] && [ "$IMPORT_ID" != "None" ]; then
      echo "  Import pending confirmation. Confirming..."
      CONFIRM_RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/apps/imports/$IMPORT_ID/confirm")
      APP_ID=$(_jq "d=json.load(sys.stdin); print(d.get('app_id',''))" <<< "$CONFIRM_RESP")
    fi
  fi

  echo ""
  echo "========================================="
  echo "  Setup complete!"
  echo "========================================="
  echo ""
  echo "  Knowledge Base: $DIFY_URL/datasets/$DATASET_ID/documents"
  echo "  Workflow:       $DIFY_URL/app/$APP_ID/workflow"
  echo ""
  echo "  Next: open the workflow URL above, click Publish, then use Debug & Preview."
else
  echo "ERROR: Workflow import failed (HTTP $IMPORT_CODE)."
  echo "$IMPORT_BODY"
  exit 1
fi

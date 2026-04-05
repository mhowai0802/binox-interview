#!/usr/bin/env bash
#
# Automated setup for the Deep Research Agent (G3) in Dify.
# Handles everything: model provider config, Knowledge Base creation,
# document upload, indexing, and workflow import.
#
# Prerequisites: Dify running (docker compose up -d)
# Usage: ./setup.sh [DIFY_URL]  (default: http://localhost)

set -euo pipefail

DIFY_URL="${1:-${DIFY_URL:-http://localhost}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR" 2>/dev/null' EXIT

API="$DIFY_URL/console/api"

_py() { python3 -c "import sys,json; $1"; }

echo "=== Deep Research Agent — Automated Setup ==="
echo "Dify URL: $DIFY_URL"
echo ""

# ── 1. LOGIN ──────────────────────────────────────────────
read -r -p "Dify email: " EMAIL
read -r -s -p "Dify password: " PASSWORD
echo ""

echo "→ Step 1/7: Logging in..."
LOGIN_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/login" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json; print(json.dumps({'email':'$EMAIL','password':'$PASSWORD'}))")")
HTTP_CODE=$(echo "$LOGIN_RESP" | tail -1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "  ERROR: Login failed (HTTP $HTTP_CODE). Check email/password."
  exit 1
fi
echo "  Logged in."

# ── 2. CHECK / ADD MODEL PROVIDERS ──────────────────────
echo "→ Step 2/7: Checking model providers..."

has_active_models() {
  local model_type="$1"
  local resp
  resp=$(curl -s -b "$COOKIE_JAR" "$API/workspaces/current/models/model-types/$model_type")
  _py "
data = json.load(sys.stdin).get('data', [])
active = [m for m in data if m.get('status') == 'active']
print('yes' if active else 'no')
" <<< "$resp"
}

get_first_embedding() {
  local resp
  resp=$(curl -s -b "$COOKIE_JAR" "$API/workspaces/current/models/model-types/text-embedding")
  _py "
data = json.load(sys.stdin).get('data', [])
active = [m for m in data if m.get('status') == 'active']
if not active:
    print('NONE|NONE')
else:
    m = active[0]
    provider = m.get('provider', {}).get('provider', '')
    model = m.get('model', '')
    print(f'{provider}|{model}')
" <<< "$resp"
}

HAS_LLM=$(has_active_models "llm")
HAS_EMB=$(has_active_models "text-embedding")

if [ "$HAS_LLM" = "yes" ] && [ "$HAS_EMB" = "yes" ]; then
  echo "  LLM and embedding models already configured."
else
  echo ""
  echo "  Missing models detected (LLM: $HAS_LLM, Embedding: $HAS_EMB)."
  echo "  Let's add an OpenAI API key to configure both."
  echo ""
  read -r -p "  OpenAI API key (sk-...): " OPENAI_KEY

  if [ -z "$OPENAI_KEY" ]; then
    echo "  ERROR: API key is required. Add models manually in Dify Settings → Model Providers."
    exit 1
  fi

  echo "  Adding OpenAI provider credentials..."
  ADD_RESP=$(curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST \
    "$API/workspaces/current/model-providers/langgenius/openai/openai/credentials" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'credentials': {'openai_api_key': '$OPENAI_KEY'}}))")")
  ADD_CODE=$(echo "$ADD_RESP" | tail -1)

  if [ "$ADD_CODE" = "201" ] || [ "$ADD_CODE" = "200" ]; then
    echo "  OpenAI provider added successfully."
  else
    ADD_BODY=$(echo "$ADD_RESP" | sed '$d')
    echo "  WARNING: Could not add OpenAI provider (HTTP $ADD_CODE)."
    echo "  $ADD_BODY"
    echo ""
    echo "  This may happen if the OpenAI plugin is not installed in your Dify instance."
    echo "  Please add model providers manually: Settings → Model Providers → OpenAI → paste API key"
    echo ""
    read -r -p "  Press Enter to continue after adding models manually, or Ctrl+C to abort..."
  fi

  sleep 2
  HAS_LLM=$(has_active_models "llm")
  HAS_EMB=$(has_active_models "text-embedding")

  if [ "$HAS_LLM" != "yes" ]; then
    echo "  ERROR: Still no active LLM models. Please configure manually and re-run."
    exit 1
  fi
  if [ "$HAS_EMB" != "yes" ]; then
    echo "  ERROR: Still no active embedding models. Please configure manually and re-run."
    exit 1
  fi
  echo "  Models verified: LLM ✓, Embedding ✓"
fi

EMBEDDING_INFO=$(get_first_embedding)
EMB_PROVIDER=$(echo "$EMBEDDING_INFO" | cut -d'|' -f1)
EMB_MODEL=$(echo "$EMBEDDING_INFO" | cut -d'|' -f2)
echo "  Embedding model: $EMB_MODEL ($EMB_PROVIDER)"

# ── 3. UPLOAD FILES ───────────────────────────────────────
echo "→ Step 3/7: Uploading sample documents..."
FILE_IDS=()
for f in "$SCRIPT_DIR/dify/sample_knowledge/"*.txt; do
  RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/files/upload" \
    -F "file=@$f" -F "source=datasets")
  FILE_ID=$(_py "print(json.load(sys.stdin)['id'])" <<< "$RESP")
  FILE_IDS+=("$FILE_ID")
  echo "  $(basename "$f") → $FILE_ID"
done

# ── 4. CREATE KNOWLEDGE BASE + INDEX DOCUMENTS ───────────
echo "→ Step 4/7: Creating Knowledge Base..."
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

DATASET_ID=$(_py "print(json.load(sys.stdin)['dataset']['id'])" <<< "$INIT_RESP")
if [ -z "$DATASET_ID" ] || [ "$DATASET_ID" = "None" ]; then
  echo "  ERROR: Failed to create Knowledge Base."
  echo "  $INIT_RESP"
  exit 1
fi
echo "  Knowledge Base ID: $DATASET_ID"

# ── 5. WAIT FOR INDEXING ─────────────────────────────────
echo "→ Step 5/7: Waiting for document indexing..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  DOC_RESP=$(curl -s -b "$COOKIE_JAR" "$API/datasets/$DATASET_ID/documents?page=1&limit=20")
  STATUS=$(_py "
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
    echo "  ERROR: Document indexing failed. Check Dify logs."
    exit 1
  fi

  sleep 3
  WAITED=$((WAITED + 3))
  printf "  ... %ds\r" "$WAITED"
done

if [ $WAITED -ge $MAX_WAIT ]; then
  echo "  WARNING: Indexing not finished after ${MAX_WAIT}s. Continuing anyway (it will complete in the background)."
fi

# ── 6. PATCH YAML WITH REAL KB ID ────────────────────────
echo "→ Step 6/7: Preparing workflow YAML..."
YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
print(json.dumps(content))
")

# ── 7. IMPORT WORKFLOW ────────────────────────────────────
echo "→ Step 7/7: Importing workflow into Dify..."
IMPORT_RESP=$(curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST "$API/apps/imports" \
  -H "Content-Type: application/json" \
  -d "{\"mode\": \"yaml-content\", \"yaml_content\": $YAML_CONTENT}")

IMPORT_CODE=$(echo "$IMPORT_RESP" | tail -1)
IMPORT_BODY=$(echo "$IMPORT_RESP" | sed '$d')

if [ "$IMPORT_CODE" = "200" ] || [ "$IMPORT_CODE" = "202" ]; then
  APP_ID=$(_py "d=json.load(sys.stdin); print(d.get('app_id',''))" <<< "$IMPORT_BODY")

  if [ "$IMPORT_CODE" = "202" ]; then
    IMPORT_ID=$(_py "d=json.load(sys.stdin); print(d.get('import_id', d.get('id','')))" <<< "$IMPORT_BODY")
    if [ -n "$IMPORT_ID" ] && [ "$IMPORT_ID" != "None" ]; then
      echo "  Import pending confirmation. Confirming..."
      CONFIRM_RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/apps/imports/$IMPORT_ID/confirm")
      APP_ID=$(_py "d=json.load(sys.stdin); print(d.get('app_id',''))" <<< "$CONFIRM_RESP")
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
  echo "  Next steps:"
  echo "    1. Open the workflow URL above"
  echo "    2. Click 'Publish' (top-right)"
  echo "    3. Use 'Debug & Preview' to test with a query"
  echo ""
else
  echo "  ERROR: Workflow import failed (HTTP $IMPORT_CODE)."
  echo "  $IMPORT_BODY"
  exit 1
fi

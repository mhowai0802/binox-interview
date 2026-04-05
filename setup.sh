#!/usr/bin/env bash
#
# Automated setup for the Deep Research Agent (G3) in Dify.
# Handles everything: plugin install, model provider config, Knowledge Base
# creation, document upload, indexing, and workflow import.
#
# Prerequisites: Dify running (docker compose up -d), curl, python3, bash
# Usage: ./setup.sh [DIFY_URL]  (default: http://localhost)

set -euo pipefail

DIFY_URL="${1:-${DIFY_URL:-http://localhost}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR" 2>/dev/null' EXIT

API="$DIFY_URL/console/api"

_py() { python3 -c "import sys,json; $1"; }

_api_get()  { curl -s -b "$COOKIE_JAR" "$API$1"; }
_api_post() { curl -s -b "$COOKIE_JAR" -X POST "$API$1" -H "Content-Type: application/json" -d "$2"; }
_api_post_status() { curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST "$API$1" -H "Content-Type: application/json" -d "$2"; }

echo "================================================"
echo "  Deep Research Agent (G3) — Automated Setup"
echo "================================================"
echo "Dify: $DIFY_URL"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 1: LOGIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
read -r -p "Dify email: " EMAIL
read -r -s -p "Dify password: " PASSWORD
echo ""

echo ""
echo "[1/7] Logging in..."
B64_PASS=$(python3 -c "import base64; print(base64.b64encode('$PASSWORD'.encode()).decode())")
LOGIN_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/login" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json; print(json.dumps({'email':'$EMAIL','password':'$B64_PASS'}))")")
HTTP_CODE=$(echo "$LOGIN_RESP" | tail -1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "  ERROR: Login failed (HTTP $HTTP_CODE). Check email/password."
  exit 1
fi
echo "  OK"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 2: CHOOSE & CONFIGURE MODEL PROVIDER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
has_active_models() {
  _api_get "/workspaces/current/models/model-types/$1" | _py "
data = json.load(sys.stdin).get('data', [])
print('yes' if [m for m in data if m.get('status') == 'active'] else 'no')"
}

get_first_embedding() {
  _api_get "/workspaces/current/models/model-types/text-embedding" | _py "
data = json.load(sys.stdin).get('data', [])
active = [m for m in data if m.get('status') == 'active']
if not active: print('NONE|NONE')
else:
    m = active[0]
    print(f\"{m.get('provider',{}).get('provider','')}\|{m.get('model','')}\")"
}

install_plugin() {
  local plugin_id="$1"
  echo "  Installing plugin: $plugin_id ..."
  local pkg_id
  pkg_id=$(curl -s "https://marketplace.dify.ai/api/v1/plugins/$plugin_id" \
    -H "Accept: application/json" | _py "print(json.load(sys.stdin)['data']['plugin']['latest_package_identifier'])")
  local resp
  resp=$(_api_post "/workspaces/current/plugin/install/marketplace" \
    "{\"plugin_unique_identifiers\": [\"$pkg_id\"]}")
  local ok
  ok=$(echo "$resp" | _py "
d = json.load(sys.stdin)
tasks = d.get('all_installed', d.get('task_id', d.get('data', '')))
print('yes' if tasks else 'no')" 2>/dev/null || echo "no")
  if [ "$ok" = "yes" ]; then
    echo "  Installed."
  else
    echo "  Plugin may already be installed or is being installed in background."
  fi
  sleep 3
}

echo ""
echo "[2/7] Configuring model providers..."

HAS_LLM=$(has_active_models "llm")
HAS_EMB=$(has_active_models "text-embedding")

if [ "$HAS_LLM" = "yes" ] && [ "$HAS_EMB" = "yes" ]; then
  echo "  LLM and embedding models already configured. Skipping."
  PROVIDER_CHOICE="skip"
else
  echo ""
  echo "  Which LLM API do you want to use?"
  echo "    1) OpenAI  (needs OpenAI API key — covers LLM + embedding)"
  echo "    2) HKBU GenAI API  (needs HKBU API key + OpenAI key for embedding)"
  echo "    3) Skip  (already configured manually)"
  echo ""
  read -r -p "  Choice [1/2/3]: " PROVIDER_CHOICE

  case "$PROVIDER_CHOICE" in
    1)
      read -r -p "  OpenAI API key (sk-...): " OPENAI_KEY
      echo "  Installing OpenAI plugin..."
      install_plugin "langgenius/openai"

      echo "  Adding OpenAI credentials..."
      ADD_RESP=$(_api_post_status "/workspaces/current/model-providers/langgenius/openai/openai/credentials" \
        "$(python3 -c "import json; print(json.dumps({'credentials': {'openai_api_key': '$OPENAI_KEY'}}))")")
      ADD_CODE=$(echo "$ADD_RESP" | tail -1)
      if [ "$ADD_CODE" = "201" ] || [ "$ADD_CODE" = "200" ]; then
        echo "  OpenAI provider configured."
      else
        echo "  WARNING: Could not add OpenAI credentials (HTTP $ADD_CODE)."
        echo "  $(echo "$ADD_RESP" | sed '$d')"
        echo "  Please add manually: Settings → Model Providers → OpenAI"
        read -r -p "  Press Enter after adding manually, or Ctrl+C to abort..."
      fi
      ;;

    2)
      read -r -p "  HKBU API key: " HKBU_KEY
      read -r -p "  OpenAI API key (for embedding model): " OPENAI_KEY

      echo "  Installing Azure OpenAI plugin (for HKBU LLM)..."
      install_plugin "langgenius/azure_openai"
      echo "  Installing OpenAI plugin (for embedding)..."
      install_plugin "langgenius/openai"

      echo "  Adding HKBU LLM (gpt-4.1)..."
      HKBU_CRED=$(python3 -c "
import json
print(json.dumps({
    'model': 'gpt-4.1',
    'model_type': 'llm',
    'credentials': {
        'openai_api_base': 'https://genai.hkbu.edu.hk/api/v0/rest',
        'auth_method': 'api_key',
        'openai_api_key': '$HKBU_KEY',
        'openai_api_version': '2024-12-01-preview',
        'base_model_name': 'gpt-4.1'
    }
}))")
      ADD_RESP=$(_api_post_status \
        "/workspaces/current/model-providers/langgenius/azure_openai/azure_openai/models/credentials" \
        "$HKBU_CRED")
      ADD_CODE=$(echo "$ADD_RESP" | tail -1)
      if [ "$ADD_CODE" = "201" ] || [ "$ADD_CODE" = "200" ]; then
        echo "  HKBU LLM configured."
      else
        echo "  WARNING: Could not add HKBU LLM (HTTP $ADD_CODE)."
        echo "  $(echo "$ADD_RESP" | sed '$d')"
      fi

      echo "  Adding OpenAI embedding model..."
      ADD_RESP=$(_api_post_status "/workspaces/current/model-providers/langgenius/openai/openai/credentials" \
        "$(python3 -c "import json; print(json.dumps({'credentials': {'openai_api_key': '$OPENAI_KEY'}}))")")
      ADD_CODE=$(echo "$ADD_RESP" | tail -1)
      if [ "$ADD_CODE" = "201" ] || [ "$ADD_CODE" = "200" ]; then
        echo "  OpenAI embedding configured."
      else
        echo "  WARNING: Could not add OpenAI credentials (HTTP $ADD_CODE)."
      fi
      ;;

    3|skip)
      PROVIDER_CHOICE="skip"
      echo "  Skipping model provider setup."
      ;;

    *)
      echo "  Invalid choice. Exiting."
      exit 1
      ;;
  esac

  sleep 2

  HAS_LLM=$(has_active_models "llm")
  HAS_EMB=$(has_active_models "text-embedding")
  if [ "$HAS_LLM" != "yes" ]; then
    echo "  ERROR: No active LLM found. Please configure a model provider and re-run."
    exit 1
  fi
  if [ "$HAS_EMB" != "yes" ]; then
    echo "  ERROR: No active embedding model found. Please configure and re-run."
    exit 1
  fi
  echo "  Models verified: LLM ✓  Embedding ✓"
fi

EMBEDDING_INFO=$(get_first_embedding)
EMB_PROVIDER=$(echo "$EMBEDDING_INFO" | cut -d'|' -f1)
EMB_MODEL=$(echo "$EMBEDDING_INFO" | cut -d'|' -f2)
echo "  Embedding: $EMB_MODEL"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 3: UPLOAD FILES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[3/7] Uploading sample documents..."
FILE_IDS=()
for f in "$SCRIPT_DIR/dify/sample_knowledge/"*.txt; do
  RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$API/files/upload" \
    -F "file=@$f" -F "source=datasets")
  FILE_ID=$(_py "print(json.load(sys.stdin)['id'])" <<< "$RESP")
  FILE_IDS+=("$FILE_ID")
  echo "  $(basename "$f") → $FILE_ID"
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4: CREATE KNOWLEDGE BASE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[4/7] Creating Knowledge Base + indexing..."
FILE_IDS_JSON=$(printf '"%s",' "${FILE_IDS[@]}" | sed 's/,$//')

INIT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'AI Regulation Research',
    'indexing_technique': 'high_quality',
    'doc_form': 'text_model',
    'doc_language': 'English',
    'embedding_model': '$EMB_MODEL',
    'embedding_model_provider': '$EMB_PROVIDER',
    'data_source': {
        'info_list': {
            'data_source_type': 'upload_file',
            'file_info_list': {'file_ids': [$FILE_IDS_JSON]}
        }
    },
    'process_rule': {'mode': 'automatic'}
}))")

INIT_RESP=$(_api_post "/datasets/init" "$INIT_PAYLOAD")
DATASET_ID=$(_py "print(json.load(sys.stdin)['dataset']['id'])" <<< "$INIT_RESP")
if [ -z "$DATASET_ID" ] || [ "$DATASET_ID" = "None" ]; then
  echo "  ERROR: Failed to create Knowledge Base."
  echo "  $INIT_RESP"
  exit 1
fi
echo "  KB ID: $DATASET_ID"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5: WAIT FOR INDEXING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[5/7] Waiting for indexing..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  DOC_RESP=$(_api_get "/datasets/$DATASET_ID/documents?page=1&limit=20")
  STATUS=$(_py "
data = json.load(sys.stdin).get('data', [])
if not data: print('waiting')
elif all(d.get('indexing_status') == 'completed' for d in data): print('done')
elif any(d.get('indexing_status') == 'error' for d in data): print('error')
else: print('waiting')" <<< "$DOC_RESP")

  if [ "$STATUS" = "done" ]; then
    echo "  Indexing complete!"
    break
  elif [ "$STATUS" = "error" ]; then
    echo "  ERROR: Indexing failed. Check Dify logs."
    exit 1
  fi

  sleep 3
  WAITED=$((WAITED + 3))
  printf "\r  ... %ds" "$WAITED"
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
  echo "  WARNING: Indexing not done after ${MAX_WAIT}s. Continuing (it will finish in background)."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6: PATCH WORKFLOW YAML
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "[6/7] Preparing workflow..."

if [ "${PROVIDER_CHOICE:-}" = "2" ]; then
  YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
content = content.replace('provider: langgenius/openai/openai', 'provider: langgenius/azure_openai/azure_openai')
content = content.replace('name: gpt-4o-mini', 'name: gpt-4.1')
print(json.dumps(content))")
  echo "  Patched: KB ID + HKBU model (gpt-4.1 via Azure OpenAI)"
else
  YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
print(json.dumps(content))")
  echo "  Patched: KB ID"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7: IMPORT WORKFLOW
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[7/7] Importing workflow..."
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
      echo "  Confirming import..."
      CONFIRM_RESP=$(_api_post "/apps/imports/$IMPORT_ID/confirm" "{}")
      APP_ID=$(_py "d=json.load(sys.stdin); print(d.get('app_id',''))" <<< "$CONFIRM_RESP")
    fi
  fi

  echo ""
  echo "================================================"
  echo "  Setup complete!"
  echo "================================================"
  echo ""
  echo "  Knowledge Base : $DIFY_URL/datasets/$DATASET_ID/documents"
  echo "  Workflow        : $DIFY_URL/app/$APP_ID/workflow"
  echo ""
  echo "  Next:"
  echo "    1. Open the workflow URL"
  echo "    2. Click 'Publish'"
  echo "    3. Use 'Debug & Preview' to test"
  echo ""
  echo "  Try this query:"
  echo "    Compare the economic impact of AI regulation in the EU vs"
  echo "    the US. How might it affect tech startups?"
  echo ""
else
  echo "  ERROR: Import failed (HTTP $IMPORT_CODE)."
  echo "  $IMPORT_BODY"
  exit 1
fi

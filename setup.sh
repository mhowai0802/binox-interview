#!/usr/bin/env bash
#
# Fully automated setup for the Deep Research Agent (G3) in Dify.
# Reads all configuration from .env — no interactive prompts.
#
# What it does:
#   1. Registers a Dify admin account (if first run)
#   2. Installs model provider plugins from marketplace
#   3. Configures LLM + embedding credentials
#   4. Creates a Knowledge Base and uploads sample documents
#   5. Waits for vector indexing
#   6. Imports the workflow with correct KB ID + model references
#
# Prerequisites: Dify running (docker compose up -d), curl, python3, bash
# Usage: cp .env.example .env  (fill in API keys)  →  ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env  and fill in your API keys."
  exit 1
fi

set -a
# shellcheck source=.env
source "$ENV_FILE"
set +a

: "${DIFY_URL:=http://localhost}"
: "${DIFY_ADMIN_EMAIL:?Set DIFY_ADMIN_EMAIL in .env}"
: "${DIFY_ADMIN_NAME:=Admin}"
: "${DIFY_ADMIN_PASSWORD:?Set DIFY_ADMIN_PASSWORD in .env}"
: "${LLM_PROVIDER:=openai}"
: "${HKBU_LLM_MODEL:=gpt-4.1}"
: "${HKBU_EMBEDDING_MODEL:=text-embedding-3-small}"

if [ "$LLM_PROVIDER" = "hkbu" ] && [ -z "${HKBU_API_KEY:-}" ]; then
  echo "ERROR: LLM_PROVIDER=hkbu but HKBU_API_KEY is empty. Set it in .env."
  exit 1
fi
if [ "$LLM_PROVIDER" = "openai" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: LLM_PROVIDER=openai but OPENAI_API_KEY is empty. Set it in .env."
  exit 1
fi

API="$DIFY_URL/console/api"
COOKIE_JAR=$(mktemp)
CSRF_TOKEN=""
trap 'rm -f "$COOKIE_JAR" 2>/dev/null' EXIT

_py() { python3 -c "import sys,json; json.load=lambda f,**kw: json.loads(f.read(),strict=False); $1"; }

_read_csrf() {
  CSRF_TOKEN=$(python3 -c "
import sys
for line in open('$COOKIE_JAR'):
    parts = line.strip().split('\t')
    if len(parts) >= 7 and parts[5] == 'csrf_token':
        print(parts[6]); break
else:
    print('')
")
}

_api_get()  { curl -s -b "$COOKIE_JAR" -H "X-CSRF-Token: $CSRF_TOKEN" "$API$1"; }
_api_post() { curl -s -b "$COOKIE_JAR" -X POST "$API$1" -H "Content-Type: application/json" -H "X-CSRF-Token: $CSRF_TOKEN" -d "$2"; }
_api_post_status() { curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST "$API$1" -H "Content-Type: application/json" -H "X-CSRF-Token: $CSRF_TOKEN" -d "$2"; }

echo "================================================"
echo "  Deep Research Agent (G3) — Automated Setup"
echo "================================================"
echo "Dify URL : $DIFY_URL"
echo "Provider : $LLM_PROVIDER"
echo "Email    : $DIFY_ADMIN_EMAIL"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 1: REGISTER + LOGIN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "[1/7] Account setup..."

SETUP_STATUS=$(curl -s "$API/setup" | _py "print(json.load(sys.stdin).get('step','unknown'))")

if [ "$SETUP_STATUS" = "not_started" ]; then
  echo "  First-time setup — registering admin account..."

  INIT_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/init" \
    -H "Content-Type: application/json" \
    -d '{"password":""}')

  SETUP_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'email': '$DIFY_ADMIN_EMAIL',
    'name': '$DIFY_ADMIN_NAME',
    'password': '$DIFY_ADMIN_PASSWORD'
}))")

  REG_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/setup" \
    -H "Content-Type: application/json" \
    -d "$SETUP_PAYLOAD")
  REG_CODE=$(echo "$REG_RESP" | tail -1)

  if [ "$REG_CODE" = "201" ] || [ "$REG_CODE" = "200" ]; then
    echo "  Admin account created."
  else
    echo "  WARNING: Registration returned HTTP $REG_CODE (may already exist)."
  fi
fi

echo "  Logging in..."
B64_PASS=$(python3 -c "import base64; print(base64.b64encode('$DIFY_ADMIN_PASSWORD'.encode()).decode())")
LOGIN_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'email': '$DIFY_ADMIN_EMAIL', 'password': '$B64_PASS'}))")

LOGIN_RESP=$(curl -s -w "\n%{http_code}" -c "$COOKIE_JAR" -X POST "$API/login" \
  -H "Content-Type: application/json" -d "$LOGIN_PAYLOAD")
LOGIN_CODE=$(echo "$LOGIN_RESP" | tail -1)

if [ "$LOGIN_CODE" != "200" ]; then
  echo "  ERROR: Login failed (HTTP $LOGIN_CODE)."
  echo "  $(echo "$LOGIN_RESP" | sed '$d')"
  if [ "$SETUP_STATUS" != "not_started" ]; then
    echo ""
    echo "  Dify was already set up with a different account."
    echo "  Update DIFY_ADMIN_EMAIL and DIFY_ADMIN_PASSWORD in .env to match"
    echo "  your existing Dify admin credentials, then re-run this script."
  fi
  exit 1
fi
_read_csrf
echo "  Logged in."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 2: INSTALL PLUGINS + CONFIGURE MODELS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
has_active_models() {
  _api_get "/workspaces/current/models/model-types/$1" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read(), strict=False).get('data', [])
active = [p for p in data if p.get('status') == 'active' and p.get('models')]
print('yes' if active else 'no')"
}

get_first_embedding() {
  _api_get "/workspaces/current/models/model-types/text-embedding" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read(), strict=False).get('data', [])
for p in data:
    if p.get('status') == 'active' and p.get('models'):
        m = p['models'][0]
        print(f\"{p.get('provider','NONE')}|{m.get('model','NONE')}\")
        break
else:
    print('NONE|NONE')"
}

install_plugin() {
  local plugin_id="$1"
  echo "  Installing plugin: $plugin_id ..."
  local pkg_id
  pkg_id=$(curl -s "https://marketplace.dify.ai/api/v1/plugins/$plugin_id" \
    -H "Accept: application/json" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read(), strict=False)
print(data['data']['plugin']['latest_package_identifier'])")
  echo "  Package: $pkg_id"
  local install_resp
  install_resp=$(_api_post "/workspaces/current/plugin/install/marketplace" \
    "{\"plugin_unique_identifiers\": [\"$pkg_id\"]}")
  echo "  Install response: $install_resp"

  echo "  Waiting for plugin to become ready..."
  for i in $(seq 1 15); do
    sleep 2
    local count
    count=$(_api_get "/workspaces/current/plugin/list?page=1&page_size=20" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read(), strict=False)
plugins = data.get('plugins', [])
print(len(plugins))" 2>/dev/null || echo "0")
    if [ "$count" -gt 0 ]; then
      echo "  Plugin installed."
      return 0
    fi
  done
  echo "  WARNING: Plugin not detected after 30s. Continuing anyway..."
}

echo ""
echo "[2/7] Configuring model providers..."

HAS_LLM=$(has_active_models "llm")
HAS_EMB=$(has_active_models "text-embedding")

if [ "$HAS_LLM" = "yes" ] && [ "$HAS_EMB" = "yes" ]; then
  echo "  Models already configured. Skipping."
  PROVIDER_CHOICE="skip"
else
  PROVIDER_CHOICE="$LLM_PROVIDER"

  case "$LLM_PROVIDER" in
    openai)
      install_plugin "langgenius/openai"
      echo "  Adding OpenAI credentials..."
      _api_post_status "/workspaces/current/model-providers/langgenius/openai/openai/credentials" \
        "$(python3 -c "import json; print(json.dumps({'credentials': {'openai_api_key': '$OPENAI_API_KEY'}}))")" > /dev/null
      echo "  OpenAI configured (LLM + embedding)."
      ;;

    hkbu)
      install_plugin "langgenius/azure_openai"

      echo "  Adding HKBU LLM ($HKBU_LLM_MODEL)..."
      HKBU_LLM_CRED=$(python3 -c "
import json
print(json.dumps({
    'model': '$HKBU_LLM_MODEL',
    'model_type': 'llm',
    'credentials': {
        'openai_api_base': 'https://genai.hkbu.edu.hk/api/v0/rest',
        'auth_method': 'api_key',
        'openai_api_key': '$HKBU_API_KEY',
        'openai_api_version': '2024-12-01-preview',
        'base_model_name': '$HKBU_LLM_MODEL'
    }
}))")
      _api_post_status \
        "/workspaces/current/model-providers/langgenius/azure_openai/azure_openai/models/credentials" \
        "$HKBU_LLM_CRED" > /dev/null
      echo "  HKBU LLM configured."

      echo "  Adding HKBU embedding ($HKBU_EMBEDDING_MODEL)..."
      HKBU_EMB_CRED=$(python3 -c "
import json
print(json.dumps({
    'model': '$HKBU_EMBEDDING_MODEL',
    'model_type': 'text-embedding',
    'credentials': {
        'openai_api_base': 'https://genai.hkbu.edu.hk/api/v0/rest',
        'auth_method': 'api_key',
        'openai_api_key': '$HKBU_API_KEY',
        'openai_api_version': '2024-12-01-preview',
        'base_model_name': '$HKBU_EMBEDDING_MODEL'
    }
}))")
      _api_post_status \
        "/workspaces/current/model-providers/langgenius/azure_openai/azure_openai/models/credentials" \
        "$HKBU_EMB_CRED" > /dev/null
      echo "  HKBU embedding configured."
      ;;

    *)
      echo "  ERROR: LLM_PROVIDER must be 'openai' or 'hkbu'. Got: $LLM_PROVIDER"
      exit 1
      ;;
  esac

  sleep 2

  HAS_LLM=$(has_active_models "llm")
  HAS_EMB=$(has_active_models "text-embedding")
  if [ "$HAS_LLM" != "yes" ]; then
    echo "  ERROR: No active LLM after setup. Check API keys and Dify logs."
    exit 1
  fi
  if [ "$HAS_EMB" != "yes" ]; then
    echo "  ERROR: No active embedding model after setup. Check OPENAI_API_KEY."
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
    -H "X-CSRF-Token: $CSRF_TOKEN" -F "file=@$f" -F "source=datasets")
  FILE_ID=$(_py "print(json.load(sys.stdin)['id'])" <<< "$RESP")
  FILE_IDS+=("$FILE_ID")
  echo "  $(basename "$f") → $FILE_ID"
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4: CREATE KNOWLEDGE BASE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[4/7] Creating Knowledge Base..."
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
  echo "  WARNING: Indexing not done after ${MAX_WAIT}s. Continuing."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6: PATCH WORKFLOW YAML
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "[6/7] Preparing workflow..."

if [ "$LLM_PROVIDER" = "hkbu" ]; then
  YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
content = content.replace('provider: langgenius/openai/openai', 'provider: langgenius/azure_openai/azure_openai')
content = content.replace('name: gpt-4o-mini', 'name: $HKBU_LLM_MODEL')
print(json.dumps(content))")
  echo "  Patched: KB=$DATASET_ID, model=$HKBU_LLM_MODEL (Azure OpenAI)"
else
  YAML_CONTENT=$(python3 -c "
import json
with open('$SCRIPT_DIR/dify/research-agent.yml') as f:
    content = f.read()
content = content.replace('00000000-0000-0000-0000-000000000000', '$DATASET_ID')
print(json.dumps(content))")
  echo "  Patched: KB=$DATASET_ID"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7: IMPORT WORKFLOW
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[7/7] Importing workflow..."
IMPORT_RESP=$(curl -s -w "\n%{http_code}" -b "$COOKIE_JAR" -X POST "$API/apps/imports" \
  -H "Content-Type: application/json" -H "X-CSRF-Token: $CSRF_TOKEN" \
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
  echo "  Dify login    : $DIFY_ADMIN_EMAIL / (password in .env)"
  echo "  Knowledge Base : $DIFY_URL/datasets/$DATASET_ID/documents"
  echo "  Workflow       : $DIFY_URL/app/$APP_ID/workflow"
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

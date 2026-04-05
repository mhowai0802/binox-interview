# Dify Setup Guide

## Prerequisites

- Docker & Docker Compose
- An LLM API key (HKBU GenAI API, OpenAI, or any OpenAI-compatible provider)

## 1. Install Dify (Self-Hosted)

```bash
git clone https://github.com/langgenius/dify.git
cd dify/docker
cp .env.example .env
docker compose up -d
```

Dify will be available at `http://localhost` (default port 80).
Create an admin account on first visit.

## 2. Add a Model Provider

The workflow uses 3 LLM nodes. You need at least one model configured.

### Option A: HKBU GenAI API (OpenAI-compatible)

1. Go to **Settings** (gear icon) → **Model Providers**
2. Click **+ Add Model Provider** → choose **OpenAI-API-compatible**
3. Fill in:
   - **Model Name**: `gpt-4.1`
   - **API Key**: your HKBU API key
   - **API Endpoint URL**: `https://genai.hkbu.edu.hk/api/v0/rest`
   - **Completion mode**: Chat
4. Click **Save**

### Option B: OpenAI directly

1. Go to **Settings** → **Model Providers** → **OpenAI**
2. Enter your OpenAI API key
3. The workflow defaults to `gpt-4o-mini` which will work out of the box

## 3. Create a Knowledge Base

The workflow includes a **Knowledge Base Retrieval** node for vector-based context retrieval. You must create a KB and upload documents.

### Step 3a: Create the Knowledge Base

1. Go to **Knowledge** (left sidebar)
2. Click **Create Knowledge**
3. Name it `AI Regulation Research` (or any name)
4. Click **Create**

### Step 3b: Upload Sample Documents

Upload the 3 sample documents provided in `dify/sample_knowledge/`:

1. Click **Add file** → **Upload file**
2. Upload all 3 files:
   - `eu_ai_act_overview.txt` — EU AI Act provisions and risk tiers
   - `us_ai_policy.txt` — US AI regulatory landscape
   - `ai_startup_impact.txt` — Impact on tech startups
3. Use default chunking settings (Automatic is fine)
4. Choose an embedding model (if prompted, use the default or any available embedding model)
5. Click **Save & Process** and wait for indexing to complete

### Step 3c: Copy the Knowledge Base ID

1. Open the Knowledge Base you just created
2. Look at the browser URL — it contains the KB ID:
   `http://localhost/datasets/<KB_ID>/documents`
3. Copy the `<KB_ID>` (a UUID like `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)

You'll need this ID when configuring the workflow (Step 5).

## 4. Import the Workflow

1. Go to **Studio** (left sidebar)
2. Click **Create from DSL** (or **Import DSL File**)
3. Upload `dify/research-agent.yml`
4. If prompted about version compatibility, click **Continue** to proceed

## 5. Configure the Knowledge Base Retrieval Node

After import, you must point the KB Retrieval node to your actual Knowledge Base:

1. Open the imported workflow in the editor
2. Find the **Knowledge Base Retrieval** node (between the iteration and aggregate nodes)
3. Click on it to open its settings
4. In the **Knowledge** section, remove the placeholder and select your `AI Regulation Research` Knowledge Base
5. Verify the settings:
   - **Top K**: 3
   - **Score Threshold**: 0.5
   - **Reranking**: disabled (or enable if you have a reranking model)

## 6. Update LLM Nodes (if using HKBU API)

If you used Option A above, the imported LLM nodes default to `gpt-4o-mini`. Update them:

1. Click on each of the 3 LLM nodes (**Decompose Query**, **Research Sub-Question**, **Synthesize Answer**)
2. In the model selector, switch to your HKBU model (`gpt-4.1`)
3. Click **Publish**

## 7. Test

Use the built-in **Debug & Preview** panel (top-right) to send a test query:

> Compare the economic impact of AI regulation in the EU vs the US. What are the key differences, and how might they affect tech startups?

The workflow will:
1. Decompose into 3-5 sub-questions
2. Research each sub-question (with `max_tokens=2000` per sub-query)
3. Retrieve relevant context from your Knowledge Base (top 3 chunks by similarity)
4. Aggregate results from both sources and check against the 10,000-token session budget
5. Synthesize a final cited answer with `[Source N]` and `[KB: title]` citations
6. Output a Markdown report with a budget summary table

## Troubleshooting

### Knowledge Base Retrieval node shows an error after import

This is expected — the imported workflow has a placeholder KB ID. Follow Step 5 to select your actual Knowledge Base.

### "No embedding model configured"

Go to **Settings** → **Model Providers** and add an embedding model. OpenAI's `text-embedding-3-small` works well and is inexpensive.

### KB retrieval returns no results

- Check that document indexing completed (green status in Knowledge → Documents)
- Try lowering the **Score Threshold** from 0.5 to 0.3
- Ensure your query is related to the uploaded documents' content

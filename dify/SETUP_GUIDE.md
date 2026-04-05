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

## 3. Import the Workflow

1. Go to **Studio** (left sidebar)
2. Click **Create from DSL** (or **Import DSL File**)
3. Upload `dify/research-agent.yml`
4. If prompted about version compatibility, click **Continue** to proceed

## 4. Update LLM Nodes (if using HKBU API)

If you used Option A above, the imported LLM nodes default to `gpt-4o-mini`. Update them:

1. Open the imported workflow in the editor
2. Click on each of the 3 LLM nodes (**Decompose Query**, **Research Sub-Question**, **Synthesize Answer**)
3. In the model selector, switch to your HKBU model (`gpt-4.1`)
4. Click **Publish**

## 5. Test

Use the built-in **Debug & Preview** panel (top-right) to send a test query:

> Compare the economic impact of AI regulation in the EU vs the US. What are the key differences, and how might they affect tech startups?

The workflow will:
1. Decompose into 3-5 sub-questions
2. Research each sub-question (with `max_tokens=2000` per sub-query)
3. Aggregate results and check against the 10,000-token session budget
4. Synthesize a final cited answer
5. Output a Markdown report with a budget summary table

# Dify Setup Guide

## 1. Install Dify (Self-Hosted)

```bash
git clone https://github.com/langgenius/dify.git
cd dify/docker
cp .env.example .env
docker compose up -d
```

Dify will be available at `http://localhost` (default port 80).
Create an admin account on first visit.

## 2. Add the HKBU GenAI API as a Custom Model Provider

1. Go to **Settings** (gear icon) → **Model Providers**
2. Click **+ Add Model Provider** → choose **OpenAI-API-compatible**
3. Fill in:
   - **Model Name**: `gpt-4.1`
   - **API Key**: your HKBU API key
   - **API Endpoint URL**: `https://genai.hkbu.edu.hk/api/v0/rest`
   - **Completion mode**: Chat
4. Click **Save**

> The HKBU GenAI endpoint is Azure OpenAI-compatible, so the
> OpenAI-compatible provider in Dify works out of the box.

## 3. Register the Memory Service as Custom Tools

1. Go to **Tools** → **Custom** → **Create Custom Tool**
2. Import the OpenAPI schema from `dify/openapi_tools.json` (paste the JSON)
3. Set the **Server URL** to `http://host.docker.internal:8100`
   (or `http://memory-service:8100` if both run in the same Docker network)
4. Save the tool collection

## 4. Import the Workflow

1. Go to **Studio** → **Create from DSL**
2. Upload `dify/research-agent.yml`
3. In the imported workflow, verify that:
   - All LLM nodes reference the `gpt-4.1` model you added
   - All HTTP/Tool nodes point to the memory service URL
4. Click **Publish**

## 5. Test

Use the built-in **Debug & Preview** panel to send a test query:

> "Compare the economic impact of AI regulation in the EU vs the US.
> What are the key differences, and how might they affect tech startups?"

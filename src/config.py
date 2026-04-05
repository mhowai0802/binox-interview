from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # HKBU GenAI API
    hkbu_api_key: str = ""
    hkbu_base_url: str = "https://genai.hkbu.edu.hk/api/v0/rest"
    hkbu_model_name: str = "gpt-4.1"
    hkbu_api_version: str = "2024-12-01-preview"

    # Memory constraints
    max_tokens_per_subquery: int = 2000
    max_tokens_per_session: int = 10000
    max_subquestions: int = 5

    # Web search
    enable_web_search: bool = True
    web_search_max_results: int = 5

    # Service
    memory_service_host: str = "0.0.0.0"
    memory_service_port: int = 8100
    chroma_persist_dir: str = "./chroma_data"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()

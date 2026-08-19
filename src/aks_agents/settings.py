from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import AnyHttpUrl, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_file=".env",
        extra="ignore",
        case_sensitive=False,
        populate_by_name=True,
    )

    service_name: str = "web-api"
    host: str = "0.0.0.0"
    port: int = 8000
    log_level: str = "info"
    development_mode: bool = False

    auth_local_dev_bypass: bool = False
    jwt_issuer: str | None = None
    jwt_audience: str | None = None
    jwt_jwks_url: AnyHttpUrl | None = None
    jwt_algorithms: list[str] = Field(default_factory=lambda: ["RS256"])
    required_agent_role: str = "Agent.Invoke"
    meal_planner_required_role: str = "MealPlan.Request"
    availability_required_role: str = "Availability.Request"
    inventory_mcp_required_role: str = "Inventory.Read"

    token_provider: Literal["sidecar", "direct", "none"] = "none"
    sidecar_token_url: AnyHttpUrl | None = None
    sidecar_timeout_seconds: float = 5.0
    sidecar_services: dict[str, str] = Field(default_factory=dict)
    tenant_id: str | None = None
    agent_blueprint_client_id: str | None = None
    agent_identity_client_id: str | None = None
    federated_token_file: Path | None = Field(
        default=None, validation_alias="AZURE_FEDERATED_TOKEN_FILE"
    )
    direct_exchange_timeout_seconds: float = 10.0
    direct_token_expiry_skew_seconds: int = 60

    agent_transport: Literal["local", "http"] = "local"
    concierge_url: AnyHttpUrl | None = Field(
        default=None, validation_alias="CONCIERGE_URL"
    )
    meal_planner_url: AnyHttpUrl | None = Field(
        default=None, validation_alias="MEAL_PLANNER_URL"
    )
    availability_url: AnyHttpUrl | None = Field(
        default=None, validation_alias="AVAILABILITY_URL"
    )
    inventory_mcp_url: AnyHttpUrl | None = Field(
        default=None, validation_alias="INVENTORY_MCP_URL"
    )
    meal_planner_audience: str | None = None
    availability_audience: str | None = None
    inventory_mcp_audience: str | None = None

    retrieval_mode: Literal["local", "azure-search"] = "azure-search"
    data_directory: Path = Path("data")
    azure_search_endpoint: AnyHttpUrl | None = None
    azure_search_index: str | None = None
    azure_search_semantic_configuration: str | None = None
    uami_client_id: str | None = None

    foundry_enabled: bool = False
    foundry_endpoint: AnyHttpUrl | None = None
    foundry_model: str | None = None
    foundry_api_version: str = "2024-10-21"
    agent_framework_enabled: bool = False

    otel_service_name: str | None = None
    otel_exporter_otlp_endpoint: AnyHttpUrl | None = None
    applicationinsights_connection_string: str | None = Field(
        default=None, validation_alias="APPLICATIONINSIGHTS_CONNECTION_STRING"
    )

    inventory_mcp_host: str = "0.0.0.0"
    inventory_mcp_port: int = 8004

    @model_validator(mode="after")
    def validate_security(self) -> "Settings":
        if self.auth_local_dev_bypass and not self.development_mode:
            raise ValueError("APP_AUTH_LOCAL_DEV_BYPASS requires APP_DEVELOPMENT_MODE=true")
        return self

    def require_cloud_search(self) -> None:
        if not self.azure_search_endpoint or not self.azure_search_index:
            raise RuntimeError(
                "Azure Search mode requires APP_AZURE_SEARCH_ENDPOINT and "
                "APP_AZURE_SEARCH_INDEX; use APP_DEVELOPMENT_MODE=true and "
                "APP_RETRIEVAL_MODE=local for the explicit developer fallback"
            )


@lru_cache
def get_settings() -> Settings:
    return Settings()

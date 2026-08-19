from __future__ import annotations

import asyncio
from dataclasses import dataclass
from time import monotonic
from typing import Protocol
from urllib.parse import quote

import httpx
from pydantic import BaseModel, ValidationError

from .settings import Settings


class TokenProviderError(RuntimeError):
    pass


class UnsupportedTokenExchangeError(TokenProviderError):
    pass


class AgentTokenProvider(Protocol):
    async def get_token(self, target_audience: str) -> str: ...


class _TokenResponse(BaseModel):
    access_token: str
    token_type: str = "Bearer"
    expires_in: int = 3600


class _SidecarResponse(BaseModel):
    authorizationHeader: str


@dataclass(frozen=True)
class _CachedToken:
    token: str
    expires_at: float


class NoTokenProvider:
    async def get_token(self, target_audience: str) -> str:
        raise TokenProviderError("No outbound agent token provider is configured")


class SidecarAgentTokenProvider:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._url = settings.sidecar_token_url
        self._timeout = settings.sidecar_timeout_seconds

    async def get_token(self, target_audience: str) -> str:
        settings = self._settings
        service_name = settings.sidecar_services.get(target_audience)
        if not self._url or not settings.agent_identity_client_id or not service_name:
            raise TokenProviderError(
                "Sidecar token provider requires APP_SIDECAR_TOKEN_URL, "
                "APP_AGENT_IDENTITY_CLIENT_ID, and an audience entry in "
                "APP_SIDECAR_SERVICES"
            )
        url = (
            f"{str(self._url).rstrip('/')}/AuthorizationHeaderUnauthenticated/"
            f"{quote(service_name, safe='')}"
        )
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.get(
                    url,
                    params={"AgentIdentity": settings.agent_identity_client_id},
                    headers={"accept": "application/json"},
                )
                response.raise_for_status()
            payload = _SidecarResponse.model_validate(response.json())
        except (httpx.HTTPError, ValidationError, ValueError) as exc:
            raise TokenProviderError("Sidecar token acquisition failed") from exc
        scheme, separator, token = payload.authorizationHeader.partition(" ")
        if separator != " " or scheme.casefold() != "bearer" or not token:
            raise TokenProviderError("Sidecar returned an unsupported token response")
        return token


class DirectAgentTokenProvider:
    """Experimental implementation of the documented autonomous Agent ID flow."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._cache: dict[str, _CachedToken] = {}
        self._lock = asyncio.Lock()

    async def get_token(self, target_audience: str) -> str:
        settings = self._settings
        if not (
            settings.tenant_id
            and settings.agent_blueprint_client_id
            and settings.agent_identity_client_id
            and settings.federated_token_file
            and target_audience
        ):
            raise UnsupportedTokenExchangeError(
                "Direct Agent ID authentication requires APP_TENANT_ID, "
                "APP_AGENT_BLUEPRINT_CLIENT_ID, APP_AGENT_IDENTITY_CLIENT_ID, "
                "AZURE_FEDERATED_TOKEN_FILE, and a target audience"
            )
        cached = self._cache.get(target_audience)
        if cached and cached.expires_at > monotonic():
            return cached.token
        async with self._lock:
            cached = self._cache.get(target_audience)
            if cached and cached.expires_at > monotonic():
                return cached.token
            token = await self._acquire_resource_token(target_audience)
            lifetime = max(
                1, token.expires_in - settings.direct_token_expiry_skew_seconds
            )
            self._cache[target_audience] = _CachedToken(
                token=token.access_token,
                expires_at=monotonic() + lifetime,
            )
            return token.access_token

    async def _acquire_resource_token(self, target_audience: str) -> _TokenResponse:
        settings = self._settings
        assert settings.tenant_id
        assert settings.agent_blueprint_client_id
        assert settings.agent_identity_client_id
        assert settings.federated_token_file
        endpoint = (
            f"https://login.microsoftonline.com/{settings.tenant_id}/oauth2/v2.0/token"
        )
        try:
            assertion = await asyncio.to_thread(
                settings.federated_token_file.read_text, encoding="utf-8"
            )
        except OSError as exc:
            raise TokenProviderError(
                "AKS projected identity assertion could not be read"
            ) from exc
        assertion = assertion.strip()
        if not assertion:
            raise TokenProviderError("AKS projected identity assertion is empty")
        exchange_token = await self._post_token(
            endpoint,
            {
                "client_id": settings.agent_blueprint_client_id,
                "scope": "api://AzureADTokenExchange/.default",
                "fmi_path": settings.agent_identity_client_id,
                "client_assertion_type": (
                    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                ),
                "client_assertion": assertion,
                "grant_type": "client_credentials",
            },
        )
        resource_scope = (
            target_audience
            if target_audience.endswith("/.default")
            else f"{target_audience.rstrip('/')}/.default"
        )
        return await self._post_token(
            endpoint,
            {
                "client_id": settings.agent_identity_client_id,
                "scope": resource_scope,
                "client_assertion_type": (
                    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                ),
                "client_assertion": exchange_token.access_token,
                "grant_type": "client_credentials",
            },
        )

    async def _post_token(
        self, endpoint: str, form: dict[str, str]
    ) -> _TokenResponse:
        try:
            async with httpx.AsyncClient(
                timeout=self._settings.direct_exchange_timeout_seconds
            ) as client:
                response = await client.post(
                    endpoint,
                    data=form,
                    headers={"accept": "application/json"},
                )
                response.raise_for_status()
            token = _TokenResponse.model_validate(response.json())
        except (httpx.HTTPError, ValidationError, ValueError) as exc:
            raise TokenProviderError("Microsoft Entra token request failed") from exc
        if token.token_type.casefold() != "bearer" or not token.access_token:
            raise TokenProviderError("Microsoft Entra returned an unsupported token")
        return token


def create_token_provider(settings: Settings) -> AgentTokenProvider:
    if settings.token_provider == "sidecar":
        return SidecarAgentTokenProvider(settings)
    if settings.token_provider == "direct":
        return DirectAgentTokenProvider(settings)
    return NoTokenProvider()

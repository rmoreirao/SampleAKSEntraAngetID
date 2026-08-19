from __future__ import annotations

import json
from typing import Any

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from .contracts import ProductAvailability, Substitute
from .data_store import InventoryStore
from .settings import Settings
from .token_provider import AgentTokenProvider


class LocalInventoryClient:
    def __init__(self, settings: Settings) -> None:
        if not settings.development_mode:
            raise RuntimeError("Local inventory client is restricted to development mode")
        self._store = InventoryStore(settings)

    async def check_availability(
        self, sku_or_name: str, quantity: int
    ) -> ProductAvailability:
        return self._store.check_availability(sku_or_name, quantity)

    async def find_substitutes(
        self, sku_or_name: str, limit: int
    ) -> list[Substitute]:
        return self._store.find_substitutes(sku_or_name, limit)


class McpInventoryClient:
    def __init__(
        self, settings: Settings, token_provider: AgentTokenProvider
    ) -> None:
        if not settings.inventory_mcp_url or not settings.inventory_mcp_audience:
            raise RuntimeError(
                "Production inventory access requires INVENTORY_MCP_URL and "
                "APP_INVENTORY_MCP_AUDIENCE"
            )
        self._url = str(settings.inventory_mcp_url)
        self._audience = settings.inventory_mcp_audience
        self._tokens = token_provider

    async def _call(self, tool: str, arguments: dict[str, Any]) -> Any:
        token = await self._tokens.get_token(self._audience)
        async with httpx.AsyncClient(
            timeout=20.0, headers={"authorization": f"Bearer {token}"}
        ) as client:
            async with streamable_http_client(
                self._url, http_client=client
            ) as (read_stream, write_stream, _):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    result = await session.call_tool(tool, arguments)
        if result.isError:
            raise RuntimeError(f"Inventory MCP tool failed: {tool}")
        payload: Any = result.structuredContent
        if payload is None and result.content:
            text = getattr(result.content[0], "text", None)
            if isinstance(text, str):
                payload = json.loads(text)
        if isinstance(payload, dict) and set(payload) == {"result"}:
            payload = payload["result"]
        if payload is None:
            raise RuntimeError(f"Inventory MCP tool returned no structured result: {tool}")
        return payload

    async def check_availability(
        self, sku_or_name: str, quantity: int
    ) -> ProductAvailability:
        payload = await self._call(
            "check_availability",
            {"sku_or_name": sku_or_name, "quantity": quantity},
        )
        return ProductAvailability.model_validate(payload)

    async def find_substitutes(
        self, sku_or_name: str, limit: int
    ) -> list[Substitute]:
        payload = await self._call(
            "find_substitutes", {"sku_or_name": sku_or_name, "limit": limit}
        )
        return [Substitute.model_validate(item) for item in payload]

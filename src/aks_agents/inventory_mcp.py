from __future__ import annotations

from typing import Any

import uvicorn
from fastapi import HTTPException
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

from .auth import JwtValidator
from .data_store import InventoryStore
from .settings import Settings

settings = Settings(service_name="inventory-mcp", port=8004)
mcp = FastMCP(
    name="inventory-mcp",
    instructions="Read-only grocery inventory discovery and substitution tools.",
    host=settings.inventory_mcp_host,
    port=settings.inventory_mcp_port,
    streamable_http_path="/mcp",
    stateless_http=True,
    json_response=True,
)


def _store() -> InventoryStore:
    store = getattr(mcp, "_inventory_store", None)
    if store is None:
        store = InventoryStore(settings)
        setattr(mcp, "_inventory_store", store)
    return store


@mcp.tool()
def search_products(query: str, limit: int = 10) -> list[dict[str, Any]]:
    """Search seeded products by name, category, and tags."""
    safe_limit = min(max(limit, 1), 50)
    return [
        product.model_dump(mode="json")
        for product in _store().search_products(query, safe_limit)
    ]


@mcp.tool()
def check_availability(sku_or_name: str, quantity: int = 1) -> dict[str, Any]:
    """Check whether a product has at least the requested quantity."""
    return _store().check_availability(sku_or_name, max(quantity, 1)).model_dump(
        mode="json"
    )


@mcp.tool()
def find_substitutes(sku_or_name: str, limit: int = 3) -> list[dict[str, Any]]:
    """Find available products with a matching category or inventory tag."""
    safe_limit = min(max(limit, 1), 20)
    return [
        substitute.model_dump(mode="json")
        for substitute in _store().find_substitutes(sku_or_name, safe_limit)
    ]


@mcp.custom_route("/healthz", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok", "service": settings.service_name, "version": "0.1.0"})


class McpRoleAuthMiddleware:
    def __init__(self, asgi_app: Any, configured_settings: Settings) -> None:
        self.app = asgi_app
        self.settings = configured_settings
        self.validator = JwtValidator(configured_settings)

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope.get("path") == "/healthz":
            await self.app(scope, receive, send)
            return
        if self.settings.development_mode and self.settings.auth_local_dev_bypass:
            await self.app(scope, receive, send)
            return
        headers = {
            key.decode("latin-1").lower(): value.decode("latin-1")
            for key, value in scope.get("headers", [])
        }
        scheme, _, token = headers.get("authorization", "").partition(" ")
        if scheme.lower() != "bearer" or not token:
            await self._reject(scope, receive, send, 401, "Bearer token required")
            return
        try:
            principal = await self.validator.validate(token)
        except HTTPException as exc:
            await self._reject(
                scope, receive, send, exc.status_code, str(exc.detail)
            )
            return
        if self.settings.inventory_mcp_required_role not in principal.roles:
            await self._reject(
                scope, receive, send, 403, "Required application role missing"
            )
            return
        await self.app(scope, receive, send)

    @staticmethod
    async def _reject(
        scope: dict[str, Any],
        receive: Any,
        send: Any,
        status_code: int,
        detail: str,
    ) -> None:
        response = JSONResponse({"detail": detail}, status_code=status_code)
        await response(scope, receive, send)


app = McpRoleAuthMiddleware(mcp.streamable_http_app(), settings)


def main() -> None:
    uvicorn.run(
        app,
        host=settings.inventory_mcp_host,
        port=settings.inventory_mcp_port,
        log_level=settings.log_level,
    )


if __name__ == "__main__":
    main()

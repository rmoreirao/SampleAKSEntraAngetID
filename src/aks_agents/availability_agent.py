from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from .api import create_service_app
from .auth import Principal, require_availability_role
from .contracts import AvailabilityRequest, AvailabilityResult
from .inventory_client import LocalInventoryClient, McpInventoryClient
from .runner import run
from .services import AvailabilityService
from .settings import Settings, get_settings
from .token_provider import create_token_provider

settings = Settings(service_name="availability-agent", port=8003)
app = create_service_app(settings)
app.dependency_overrides[get_settings] = lambda: settings


def _service() -> AvailabilityService:
    service = getattr(app.state, "availability", None)
    if service is None:
        inventory = (
            LocalInventoryClient(settings)
            if settings.development_mode and not settings.inventory_mcp_url
            else McpInventoryClient(settings, create_token_provider(settings))
        )
        service = AvailabilityService(settings, inventory)
        app.state.availability = service
    return service


@app.post("/v1/availability", response_model=AvailabilityResult, tags=["agent"])
async def availability(
    request: AvailabilityRequest,
    _: Annotated[Principal, Depends(require_availability_role)],
) -> AvailabilityResult:
    return await _service().handle(request)


def main() -> None:
    run("aks_agents.availability_agent:app", settings)


if __name__ == "__main__":
    main()

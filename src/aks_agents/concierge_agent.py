from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from .api import create_service_app
from .auth import Principal, require_agent_role
from .contracts import ConciergeRequest, ConciergeResult
from .runner import run
from .services import ConciergeService
from .settings import Settings, get_settings

settings = Settings(service_name="concierge-agent", port=8001)
app = create_service_app(settings)
app.dependency_overrides[get_settings] = lambda: settings

def _service() -> ConciergeService:
    service = getattr(app.state, "concierge", None)
    if service is None:
        service = ConciergeService(settings)
        app.state.concierge = service
    return service


@app.post("/v1/concierge", response_model=ConciergeResult, tags=["agent"])
async def concierge(
    request: ConciergeRequest,
    _: Annotated[Principal, Depends(require_agent_role)],
) -> ConciergeResult:
    return await _service().handle(request)


def main() -> None:
    run("aks_agents.concierge_agent:app", settings)


if __name__ == "__main__":
    main()

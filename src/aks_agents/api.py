from __future__ import annotations

from fastapi import FastAPI

from .contracts import HealthResponse
from .settings import Settings
from .telemetry import configure_telemetry


def create_service_app(settings: Settings) -> FastAPI:
    app = FastAPI(title=settings.service_name, version="0.1.0")

    @app.get("/healthz", response_model=HealthResponse, tags=["operations"])
    async def health() -> HealthResponse:
        return HealthResponse(service=settings.service_name)

    configure_telemetry(app, settings)
    return app

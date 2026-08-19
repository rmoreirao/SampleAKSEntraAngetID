from __future__ import annotations

import uvicorn

from .settings import Settings


def run(app_path: str, settings: Settings) -> None:
    uvicorn.run(
        app_path,
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
        factory=False,
    )

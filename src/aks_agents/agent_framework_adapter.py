from __future__ import annotations

import importlib
from collections.abc import Callable
from typing import Any

from pydantic import BaseModel

from .settings import Settings


def load_agent_framework(settings: Settings) -> Any | None:
    """Load Microsoft Agent Framework only when the deployment explicitly enables it."""
    if not settings.agent_framework_enabled:
        return None
    try:
        return importlib.import_module("agent_framework")
    except ImportError as exc:
        raise RuntimeError(
            "APP_AGENT_FRAMEWORK_ENABLED=true but Microsoft Agent Framework is unavailable"
        ) from exc


def create_function_tool(
    framework: Any | None,
    *,
    name: str,
    description: str,
    function: Callable[..., Any],
    input_model: type[BaseModel],
) -> Any | None:
    if framework is None:
        return None
    return framework.FunctionTool(
        name=name,
        description=description,
        func=function,
        input_model=input_model,
    )

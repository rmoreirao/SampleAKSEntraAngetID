from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException
from fastapi.responses import StreamingResponse

from .api import create_service_app
from .auth import Principal, require_agent_role
from .contracts import (
    ChatAccepted,
    ChatRequest,
    EventType,
    InteractionEvent,
    InteractionRequest,
    InteractionResult,
    TimelineEvent,
    UiChatResult,
)
from .orchestration import Orchestrator
from .presenter import build_ui_result
from .runner import run
from .settings import Settings, get_settings

settings = Settings(service_name="web-api", port=8000)
app = create_service_app(settings)
app.dependency_overrides[get_settings] = lambda: settings
logger = logging.getLogger(__name__)


@dataclass
class _InteractionChannel:
    events: list[TimelineEvent] = field(default_factory=list)
    condition: asyncio.Condition = field(default_factory=asyncio.Condition)
    complete: bool = False
    result: UiChatResult | None = None


def _orchestrator() -> Orchestrator:
    orchestrator = getattr(app.state, "orchestrator", None)
    if orchestrator is None:
        orchestrator = Orchestrator(settings)
        app.state.orchestrator = orchestrator
    return orchestrator


def _channels() -> dict[UUID, _InteractionChannel]:
    channels = getattr(app.state, "interaction_channels", None)
    if channels is None:
        channels = {}
        app.state.interaction_channels = channels
    return channels


async def _run_interaction(
    request: InteractionRequest, channel: _InteractionChannel
) -> None:
    try:
        async for event in _orchestrator().stream(request):
            timeline = _to_timeline(event, request)
            if timeline.result:
                channel.result = timeline.result
            async with channel.condition:
                channel.events.append(timeline)
                channel.condition.notify_all()
    except Exception:
        logger.exception(
            "Interaction %s failed before producing an orchestration error event",
            request.interaction_id,
        )
        async with channel.condition:
            channel.events.append(
                TimelineEvent(
                    kind="agent-a2a",
                    source="web-api",
                    target="web-ui",
                    operation="interaction.failed",
                    status="error",
                    correlation_id=request.interaction_id,
                    detail={"message": "Interaction configuration or startup failed"},
                )
            )
            channel.condition.notify_all()
    finally:
        async with channel.condition:
            channel.complete = True
            channel.condition.notify_all()


def _to_timeline(
    event: InteractionEvent, request: InteractionRequest
) -> TimelineEvent:
    mappings = {
        EventType.ACCEPTED: (
            "orchestration",
            "web-ui",
            "concierge-agent",
            "interaction.accepted",
            "running",
        ),
        EventType.CONCIERGE: (
            "azure-uami" if settings.foundry_enabled else "orchestration",
            "concierge-agent",
            "foundry-model" if settings.foundry_enabled else "concierge-agent",
            "request.extract",
            "success",
        ),
        EventType.RAG: (
            "azure-uami",
            "meal-planner-agent",
            "azure-ai-search",
            "recipes.retrieve",
            "success",
        ),
        EventType.MEAL_PLAN: (
            "agent-a2a",
            "concierge-agent",
            "meal-planner-agent",
            "meal-plan.create",
            "success",
        ),
        EventType.INVENTORY: (
            "agent-mcp",
            "availability-agent",
            "inventory-mcp",
            "inventory.check",
            "success",
        ),
        EventType.AVAILABILITY: (
            "agent-a2a",
            "concierge-agent",
            "availability-agent",
            "availability.resolve",
            "success",
        ),
        EventType.COMPLETED: (
            "orchestration",
            "concierge-agent",
            "web-ui",
            "interaction.completed",
            "success",
        ),
        EventType.ERROR: (
            "orchestration",
            "concierge-agent",
            "web-ui",
            "interaction.failed",
            "error",
        ),
    }
    kind, source, target, operation, status = mappings[event.type]
    result = None
    if event.type == EventType.COMPLETED:
        internal = InteractionResult.model_validate(event.data)
        result = build_ui_result(request, internal, settings)
    detail = None if result else event.data
    return TimelineEvent(
        id=event.event_id,
        timestamp=event.timestamp,
        kind=kind,
        source=source,
        target=target,
        operation=operation,
        duration_ms=int(event.data.get("duration_ms", 0)),
        status=status,
        correlation_id=request.interaction_id,
        result=result,
        detail=detail,
    )


def _format_sse(event: TimelineEvent) -> str:
    return (
        f"id: {event.id}\n"
        f"data: {event.model_dump_json()}\n\n"
    )


@app.post("/api/chat", response_model=ChatAccepted, status_code=202, tags=["orchestration"])
async def chat(
    request: ChatRequest,
) -> ChatAccepted:
    interaction = request.to_interaction()
    channels = _channels()
    if interaction.interaction_id in channels:
        raise HTTPException(status_code=409, detail="Correlation id already exists")
    if len(channels) >= 100:
        completed = [key for key, value in channels.items() if value.complete]
        for key in completed[: max(1, len(channels) - 99)]:
            channels.pop(key, None)
    if len(channels) >= 100:
        raise HTTPException(
            status_code=429,
            detail="Too many active interactions; retry after an existing request completes",
        )
    channel = _InteractionChannel()
    channels[interaction.interaction_id] = channel
    task = asyncio.create_task(_run_interaction(interaction, channel))
    tasks = getattr(app.state, "interaction_tasks", None)
    if tasks is None:
        tasks = set()
        app.state.interaction_tasks = tasks
    tasks.add(task)
    task.add_done_callback(tasks.discard)
    return ChatAccepted(
        correlation_id=interaction.interaction_id,
        events_url=f"/api/interactions/{interaction.interaction_id}/events",
    )


@app.get(
    "/api/interactions/{correlation_id}/events",
    tags=["orchestration"],
)
async def correlated_interaction_events(
    correlation_id: UUID,
) -> StreamingResponse:
    channel = _channels().get(correlation_id)
    if channel is None:
        raise HTTPException(status_code=404, detail="Unknown correlation id")

    async def events():
        index = 0
        while True:
            async with channel.condition:
                await channel.condition.wait_for(
                    lambda: index < len(channel.events) or channel.complete
                )
                pending = channel.events[index:]
                index = len(channel.events)
                complete = channel.complete
            for event in pending:
                yield _format_sse(event)
            if complete and index >= len(channel.events):
                break

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"cache-control": "no-cache", "x-accel-buffering": "no"},
    )


@app.get(
    "/api/interactions/{correlation_id}/result",
    response_model=UiChatResult,
    tags=["orchestration"],
)
async def interaction_result(correlation_id: UUID) -> UiChatResult:
    channel = _channels().get(correlation_id)
    if channel is None:
        raise HTTPException(status_code=404, detail="Unknown correlation id")
    if channel.result is None:
        raise HTTPException(status_code=425, detail="Interaction is still processing")
    return channel.result


@app.post("/v1/interactions", response_model=InteractionResult, tags=["orchestration"])
async def interact(
    request: InteractionRequest,
    _: Annotated[Principal, Depends(require_agent_role)],
) -> InteractionResult:
    return await _orchestrator().run(request)


@app.post("/v1/interactions/events", tags=["orchestration"])
async def interaction_events(
    request: InteractionRequest,
    _: Annotated[Principal, Depends(require_agent_role)],
) -> StreamingResponse:
    async def events():
        async for event in _orchestrator().stream(request):
            yield (
                f"id: {event.event_id}\n"
                f"event: {event.type.value}\n"
                f"data: {event.model_dump_json()}\n\n"
            )

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"cache-control": "no-cache", "x-accel-buffering": "no"},
    )


def main() -> None:
    run("aks_agents.web_api:app", settings)


if __name__ == "__main__":
    main()

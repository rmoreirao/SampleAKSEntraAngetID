from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from time import perf_counter

from .agent_framework_adapter import create_function_tool, load_agent_framework
from .contracts import (
    AvailabilityRequest,
    ConciergeRequest,
    EventType,
    InteractionEvent,
    InteractionRequest,
    InteractionResult,
    MealPlanRequest,
)
from .inventory_client import LocalInventoryClient
from .rag import create_recipe_retriever
from .services import (
    AvailabilityService,
    ConciergeService,
    MealPlannerService,
    flatten_ingredients,
)
from .settings import Settings
from .token_provider import create_token_provider
from .transport import AgentHttpTransport

logger = logging.getLogger(__name__)


class Orchestrator:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._framework = load_agent_framework(settings)
        self._concierge = ConciergeService(settings)
        if settings.agent_transport == "http":
            self._http = AgentHttpTransport(settings, create_token_provider(settings))
            self._planner = None
            self._availability = None
        else:
            if not settings.development_mode:
                raise RuntimeError(
                    "Local agent transport is restricted to APP_DEVELOPMENT_MODE=true"
                )
            self._http = None
            self._planner = MealPlannerService(create_recipe_retriever(settings))
            self._availability = AvailabilityService(LocalInventoryClient(settings))
        self.framework_tools = self._create_framework_tools()

    def _create_framework_tools(self) -> list[object]:
        if not self._framework:
            return []
        tool_specs = [
            (
                "classify_meal_request",
                "Classify and normalize a meal-planning request.",
                self._concierge.handle,
                ConciergeRequest,
            )
        ]
        if self._planner and self._availability:
            tool_specs.extend(
                [
                    (
                        "retrieve_meal_plan",
                        "Retrieve and scale recipes for a normalized request.",
                        self._planner.handle,
                        MealPlanRequest,
                    ),
                    (
                        "check_ingredient_availability",
                        "Check inventory for the ingredients in a meal plan.",
                        self._availability.handle,
                        AvailabilityRequest,
                    ),
                ]
            )
        return [
            tool
            for name, description, function, input_model in tool_specs
            if (
                tool := create_function_tool(
                    self._framework,
                    name=name,
                    description=description,
                    function=function,
                    input_model=input_model,
                )
            )
            is not None
        ]

    async def run(self, request: InteractionRequest) -> InteractionResult:
        concierge_request = ConciergeRequest(
            message=request.message,
            dietary_preferences=request.dietary_preferences,
        )
        concierge = await self._concierge.handle(concierge_request)
        plan_request = MealPlanRequest(
            search_terms=concierge.search_terms,
            dietary_preferences=concierge.dietary_preferences,
            servings=request.servings,
        )
        if self._http:
            meal_plan = await self._http.meal_plan(plan_request)
        else:
            assert self._planner
            meal_plan = await self._planner.handle(plan_request)
        availability_request = AvailabilityRequest(
            ingredients=flatten_ingredients(meal_plan)
        )
        if self._http:
            availability = await self._http.availability(availability_request)
        else:
            assert self._availability
            availability = await self._availability.handle(availability_request)
        return InteractionResult(
            interaction_id=request.interaction_id,
            concierge=concierge,
            meal_plan=meal_plan,
            availability=availability,
        )

    async def stream(self, request: InteractionRequest) -> AsyncIterator[InteractionEvent]:
        yield InteractionEvent(
            interaction_id=request.interaction_id,
            type=EventType.ACCEPTED,
            data={"user_id": request.user_id},
        )
        try:
            concierge_request = ConciergeRequest(
                message=request.message,
                dietary_preferences=request.dietary_preferences,
            )
            started = perf_counter()
            concierge = await self._concierge.handle(concierge_request)
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.CONCIERGE,
                data={
                    **concierge.model_dump(mode="json"),
                    "duration_ms": round((perf_counter() - started) * 1000),
                },
            )
            plan_request = MealPlanRequest(
                search_terms=concierge.search_terms,
                dietary_preferences=concierge.dietary_preferences,
                servings=request.servings,
            )
            started = perf_counter()
            plan = (
                await self._http.meal_plan(plan_request)
                if self._http
                else await self._planner.handle(plan_request)  # type: ignore[union-attr]
            )
            duration_ms = round((perf_counter() - started) * 1000)
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.RAG,
                data={
                    "result_count": len(plan.recipes),
                    "duration_ms": duration_ms,
                },
            )
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.MEAL_PLAN,
                data={
                    **plan.model_dump(mode="json"),
                    "duration_ms": duration_ms,
                },
            )
            availability_request = AvailabilityRequest(
                ingredients=flatten_ingredients(plan)
            )
            started = perf_counter()
            availability = (
                await self._http.availability(availability_request)
                if self._http
                else await self._availability.handle(availability_request)  # type: ignore[union-attr]
            )
            duration_ms = round((perf_counter() - started) * 1000)
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.INVENTORY,
                data={
                    "all_available": availability.all_available,
                    "item_count": len(availability.items),
                    "duration_ms": duration_ms,
                },
            )
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.AVAILABILITY,
                data={
                    **availability.model_dump(mode="json"),
                    "duration_ms": duration_ms,
                },
            )
            result = InteractionResult(
                interaction_id=request.interaction_id,
                concierge=concierge,
                meal_plan=plan,
                availability=availability,
            )
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.COMPLETED,
                data=result.model_dump(mode="json"),
            )
        except Exception:
            logger.exception(
                "Interaction %s failed during orchestration",
                request.interaction_id,
            )
            yield InteractionEvent(
                interaction_id=request.interaction_id,
                type=EventType.ERROR,
                data={"message": "Interaction failed"},
            )

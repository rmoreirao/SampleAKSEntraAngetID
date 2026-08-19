from __future__ import annotations

from typing import TypeVar

import httpx
from pydantic import BaseModel

from .contracts import (
    AvailabilityRequest,
    AvailabilityResult,
    MealPlanRequest,
    MealPlanResult,
)
from .settings import Settings
from .token_provider import AgentTokenProvider

ResponseModel = TypeVar("ResponseModel", bound=BaseModel)


class AgentHttpTransport:
    def __init__(self, settings: Settings, token_provider: AgentTokenProvider) -> None:
        self._settings = settings
        self._tokens = token_provider

    async def _post(
        self,
        base_url: object,
        audience: str | None,
        path: str,
        request: BaseModel,
        model: type[ResponseModel],
    ) -> ResponseModel:
        if not base_url or not audience:
            raise RuntimeError(
                f"HTTP agent transport requires a service URL and audience for {path}"
            )
        token = await self._tokens.get_token(audience)
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.post(
                f"{str(base_url).rstrip('/')}{path}",
                json=request.model_dump(mode="json"),
                headers={"authorization": "Bearer " + token},
            )
            response.raise_for_status()
        return model.model_validate(response.json())

    async def meal_plan(self, request: MealPlanRequest) -> MealPlanResult:
        return await self._post(
            self._settings.meal_planner_url,
            self._settings.meal_planner_audience,
            "/v1/meal-plans",
            request,
            MealPlanResult,
        )

    async def availability(self, request: AvailabilityRequest) -> AvailabilityResult:
        return await self._post(
            self._settings.availability_url,
            self._settings.availability_audience,
            "/v1/availability",
            request,
            AvailabilityResult,
        )

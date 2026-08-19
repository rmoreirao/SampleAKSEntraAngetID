from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from .api import create_service_app
from .auth import Principal, require_meal_planner_role
from .contracts import MealPlanRequest, MealPlanResult
from .rag import create_recipe_retriever
from .runner import run
from .services import MealPlannerService
from .settings import Settings, get_settings

settings = Settings(service_name="meal-planner-agent", port=8002)
app = create_service_app(settings)
app.dependency_overrides[get_settings] = lambda: settings


def _service() -> MealPlannerService:
    service = getattr(app.state, "meal_planner", None)
    if service is None:
        service = MealPlannerService(settings, create_recipe_retriever(settings))
        app.state.meal_planner = service
    return service


@app.post("/v1/meal-plans", response_model=MealPlanResult, tags=["agent"])
async def meal_plan(
    request: MealPlanRequest,
    _: Annotated[Principal, Depends(require_meal_planner_role)],
) -> MealPlanResult:
    return await _service().handle(request)


def main() -> None:
    run("aks_agents.meal_planner_agent:app", settings)


if __name__ == "__main__":
    main()

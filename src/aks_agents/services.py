from __future__ import annotations

import math
import re
from typing import Protocol

from opentelemetry import trace

from .contracts import (
    AvailabilityRequest,
    AvailabilityResult,
    ConciergeRequest,
    ConciergeResult,
    MealPlanRequest,
    MealPlanResult,
    PlannedRecipe,
    ProductAvailability,
    RecipeIngredient,
    Substitute,
)
from .foundry import FoundryChatClient
from .rag import RecipeRetriever
from .settings import Settings

tracer = trace.get_tracer(__name__)


class ConciergeService:
    _stop_words = {
        "a",
        "an",
        "and",
        "can",
        "cook",
        "dinner",
        "for",
        "i",
        "like",
        "make",
        "meal",
        "me",
        "need",
        "please",
        "plan",
        "some",
        "the",
        "to",
        "want",
        "with",
    }

    def __init__(self, settings: Settings) -> None:
        self._development_mode = settings.development_mode
        self._foundry = FoundryChatClient(settings) if settings.foundry_enabled else None
        if not self._foundry and not self._development_mode:
            raise RuntimeError(
                "Production Concierge requires APP_FOUNDRY_ENABLED=true; deterministic "
                "extraction is restricted to APP_DEVELOPMENT_MODE=true"
            )

    async def handle(self, request: ConciergeRequest) -> ConciergeResult:
        with tracer.start_as_current_span("concierge.handle"):
            if self._foundry:
                response = await self._foundry.complete(
                    "Extract a meal request. Return JSON only with keys intent "
                    "(meal_plan, inventory_query, or unknown), search_terms (string array), "
                    "and dietary_preferences (string array). Do not add prose.",
                    request.model_dump_json(),
                )
                start, end = response.find("{"), response.rfind("}")
                if start < 0 or end <= start:
                    raise RuntimeError("Foundry Concierge returned no JSON object")
                return ConciergeResult.model_validate_json(response[start : end + 1])
            words = re.findall(r"[a-z0-9-]+", request.message.casefold())
            inventory_markers = {"stock", "available", "availability", "inventory"}
            meal_markers = {"meal", "recipe", "cook", "dinner", "lunch", "breakfast"}
            if inventory_markers.intersection(words) and not meal_markers.intersection(words):
                intent = "inventory_query"
            elif meal_markers.intersection(words) or words:
                intent = "meal_plan"
            else:
                intent = "unknown"
            terms = [
                word
                for word in words
                if word not in self._stop_words and word not in inventory_markers
            ][:12]
            return ConciergeResult(
                intent=intent,
                search_terms=terms,
                dietary_preferences=sorted(
                    {preference.casefold() for preference in request.dietary_preferences}
                ),
            )


class MealPlannerService:
    def __init__(self, retriever: RecipeRetriever) -> None:
        self._retriever = retriever

    async def handle(self, request: MealPlanRequest) -> MealPlanResult:
        with tracer.start_as_current_span("meal_planner.handle"):
            recipes = await self._retriever.retrieve(
                request.search_terms, request.dietary_preferences
            )
            plans: list[PlannedRecipe] = []
            for recipe in recipes:
                scale = request.servings / recipe.servings
                ingredients = [
                    ingredient.model_copy(
                        update={"quantity": round(ingredient.quantity * scale, 2)}
                    )
                    for ingredient in recipe.ingredients
                ]
                plans.append(PlannedRecipe(recipe=recipe, scaled_ingredients=ingredients))
            return MealPlanResult(
                recipes=plans,
                rationale=(
                    "Ranked deterministically by requested terms and dietary tags."
                    if plans
                    else "No recipe matched the requested terms and dietary tags."
                ),
            )


class InventoryClient(Protocol):
    async def check_availability(
        self, sku_or_name: str, quantity: int
    ) -> ProductAvailability: ...

    async def find_substitutes(
        self, sku_or_name: str, limit: int
    ) -> list[Substitute]: ...


class AvailabilityService:
    def __init__(self, inventory: InventoryClient) -> None:
        self._inventory = inventory

    async def handle(self, request: AvailabilityRequest) -> AvailabilityResult:
        with tracer.start_as_current_span("availability.handle"):
            items = []
            substitutes = []
            for ingredient in request.ingredients:
                required = max(1, math.ceil(ingredient.quantity))
                item = await self._inventory.check_availability(
                    ingredient.name, required
                )
                items.append(item)
                if not item.available:
                    substitutes.extend(
                        await self._inventory.find_substitutes(ingredient.name, 2)
                    )
            return AvailabilityResult(
                items=items,
                substitutes=substitutes,
                all_available=all(item.available for item in items),
            )


def flatten_ingredients(plan: MealPlanResult) -> list[RecipeIngredient]:
    combined: dict[tuple[str, str], float] = {}
    for planned in plan.recipes:
        for ingredient in planned.scaled_ingredients:
            key = (ingredient.name, ingredient.unit)
            combined[key] = combined.get(key, 0) + ingredient.quantity
    return [
        RecipeIngredient(name=name, quantity=quantity, unit=unit)
        for (name, unit), quantity in sorted(combined.items())
    ]

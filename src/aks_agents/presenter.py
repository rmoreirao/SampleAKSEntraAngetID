from __future__ import annotations

from .contracts import (
    InteractionRequest,
    InteractionResult,
    UiChatResult,
    UiCitation,
    UiIngredient,
    UiRecommendation,
)
from .settings import Settings


def build_ui_result(
    request: InteractionRequest, result: InteractionResult, settings: Settings
) -> UiChatResult:
    availability = {item.name.casefold(): item for item in result.availability.items}
    substitutes = {
        substitute.requested.casefold(): substitute
        for substitute in result.availability.substitutes
    }
    recommendations: list[UiRecommendation] = []
    citations: list[UiCitation] = []
    for planned in result.meal_plan.recipes:
        recipe = planned.recipe
        ingredients: list[UiIngredient] = []
        for ingredient in planned.scaled_ingredients:
            item = availability.get(ingredient.name.casefold())
            substitute = substitutes.get(ingredient.name.casefold())
            if item and item.available:
                status = "available"
            elif substitute:
                status = "substitute"
            else:
                status = "unavailable"
            ingredients.append(
                UiIngredient(
                    name=ingredient.name,
                    quantity=f"{ingredient.quantity:g} {ingredient.unit}",
                    status=status,
                    note=(
                        substitute.reason
                        if substitute
                        else f"{item.available_quantity:g} {item.unit} in stock"
                        if item
                        else "Not found in inventory"
                    ),
                    substitute=substitute.product.name if substitute else None,
                )
            )
        citation_id = f"recipe-{recipe.id}"
        estimated_cost = round(
            2.25 * len(planned.scaled_ingredients) + 0.75 * request.servings, 2
        )
        recommendations.append(
            UiRecommendation(
                id=recipe.id,
                title=recipe.name,
                description=recipe.description,
                prepMinutes=10 + 5 * len(recipe.instructions),
                servings=request.servings,
                estimatedCost=estimated_cost,
                tags=recipe.tags,
                ingredients=ingredients,
                citationIds=[citation_id],
            )
        )
        citations.append(
            UiCitation(
                id=citation_id,
                title=recipe.name,
                source=(
                    "Local development recipe seed"
                    if settings.retrieval_mode == "local"
                    else "Azure AI Search recipe index"
                ),
                snippet=recipe.description,
            )
        )
    total = sum(item.estimatedCost for item in recommendations)
    budget_note = (
        f" Estimated total ${total:.2f} against a ${request.budget:.2f} budget."
        if request.budget
        else f" Estimated total ${total:.2f}."
    )
    return UiChatResult(
        summary=(
            f"Prepared {len(recommendations)} recommendation(s) for "
            f"{request.servings} serving(s). {result.meal_plan.rationale}"
            f"{budget_note}"
        ),
        recommendations=recommendations,
        citations=citations,
        store=request.store,
    )

from __future__ import annotations

import json
import unittest
from collections.abc import Sequence
from typing import Any

from pydantic import BaseModel, ConfigDict

from aks_agents.contracts import (
    AvailabilityRequest,
    ConciergeResult,
    InteractionRequest,
    MealPlanRequest,
    Product,
    ProductAvailability,
    Recipe,
    RecipeIngredient,
    Substitute,
)
from aks_agents.foundry import FoundryChatClient
from aks_agents.orchestration import Orchestrator
from aks_agents.services import AvailabilityService, MealPlannerService
from aks_agents.settings import Settings


def _recipe(recipe_id: str, ingredient: str = "tomatoes") -> Recipe:
    return Recipe(
        id=recipe_id,
        name=recipe_id.replace("-", " ").title(),
        description="Grounded recipe",
        servings=2,
        ingredients=[
            RecipeIngredient(name=ingredient, quantity=2, unit="each")
        ],
        instructions=["Cook it."],
        tags=["vegetarian"],
    )


class FakeRetriever:
    def __init__(self, recipes: Sequence[Recipe]) -> None:
        self.recipes = list(recipes)

    async def retrieve(
        self,
        search_terms: list[str],
        dietary_preferences: list[str],
        limit: int = 3,
    ) -> list[Recipe]:
        return self.recipes[:limit]


class FakeFoundry:
    def __init__(self, response: dict[str, Any]) -> None:
        self.response = response
        self.requests: list[dict[str, Any]] = []

    async def complete_structured(
        self, system: str, user: str, response_model: type[BaseModel]
    ) -> BaseModel:
        self.requests.append(json.loads(user))
        return response_model.model_validate(self.response)


class FakeInventory:
    def __init__(self, substitute: Substitute | None = None) -> None:
        self.substitute = substitute

    async def check_availability(
        self, sku_or_name: str, quantity: int
    ) -> ProductAvailability:
        return ProductAvailability(
            sku="PAN-STOCK",
            name=sku_or_name,
            requested_quantity=quantity,
            available_quantity=0,
            available=False,
            unit="cup",
        )

    async def find_substitutes(
        self, sku_or_name: str, limit: int
    ) -> list[Substitute]:
        return [self.substitute] if self.substitute else []


class _StructuredResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    value: str


class _FakeCompletions:
    def __init__(self, contents: list[str]) -> None:
        self.contents = contents
        self.calls: list[dict[str, Any]] = []

    async def create(self, **kwargs: Any) -> Any:
        self.calls.append(kwargs)
        content = self.contents.pop(0)
        message = type("Message", (), {"content": content})()
        choice = type("Choice", (), {"message": message})()
        return type("Response", (), {"choices": [choice]})()


class _FakeOpenAI:
    def __init__(self, contents: list[str]) -> None:
        self.completions = _FakeCompletions(contents)
        self.chat = type("Chat", (), {"completions": self.completions})()


class FoundryClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_retries_invalid_structured_output(self) -> None:
        client = object.__new__(FoundryChatClient)
        client.model = "test-model"
        client._max_output_tokens = 100
        client._validation_retries = 1
        openai = _FakeOpenAI(["{}", '{"value":"ok"}'])
        client.client = openai

        result = await client.complete_structured(
            "system", "user", _StructuredResult
        )

        self.assertEqual("ok", result.value)
        schema = openai.completions.calls[0]["response_format"]["json_schema"][
            "schema"
        ]
        self.assertFalse(schema["additionalProperties"])


class MealPlannerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.settings = Settings(development_mode=True)

    async def test_selects_only_grounded_recipe_and_scales_in_python(self) -> None:
        foundry = FakeFoundry(
            {
                "selections": [
                    {"recipe_id": "recipe-b"}
                ]
            }
        )
        service = MealPlannerService(
            self.settings,
            FakeRetriever([_recipe("recipe-a"), _recipe("recipe-b")]),
            foundry,
        )

        result = await service.handle(
            MealPlanRequest(search_terms=["tomato"], servings=4)
        )

        self.assertEqual(["recipe-b"], result.grounding_source_ids)
        self.assertEqual(4, result.recipes[0].scaled_ingredients[0].quantity)
        self.assertTrue(result.model_used)

    async def test_rejects_ungrounded_recipe_id(self) -> None:
        foundry = FakeFoundry(
            {
                "selections": [
                    {"recipe_id": "invented"}
                ]
            }
        )
        service = MealPlannerService(
            self.settings, FakeRetriever([_recipe("recipe-a")]), foundry
        )

        with self.assertRaisesRegex(RuntimeError, "ungrounded recipe"):
            await service.handle(MealPlanRequest(search_terms=["tomato"]))

    async def test_exclusions_are_applied_before_inference(self) -> None:
        foundry = FakeFoundry({"selections": []})
        service = MealPlannerService(
            self.settings,
            FakeRetriever([_recipe("recipe-a", ingredient="peanuts")]),
            foundry,
        )

        result = await service.handle(
            MealPlanRequest(
                search_terms=["quick"], excluded_ingredients=["peanuts"]
            )
        )

        self.assertEqual([], result.recipes)
        self.assertEqual([], foundry.requests)


class AvailabilityTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.settings = Settings(development_mode=True)
        self.substitute = Substitute(
            requested="chicken stock",
            product=Product(
                sku="PAN-VEGSTOCK",
                name="vegetable stock",
                category="pantry",
                quantity=12,
                unit="cup",
                tags=["vegan", "stock"],
            ),
            reason="Inventory candidate",
        )

    async def test_preserves_inventory_facts_and_grounds_substitution(self) -> None:
        foundry = FakeFoundry(
            {
                "substitutions": [
                    {
                        "requested": "chicken stock",
                        "sku": "PAN-VEGSTOCK",
                    }
                ]
            }
        )
        service = AvailabilityService(
            self.settings, FakeInventory(self.substitute), foundry
        )

        result = await service.handle(
            AvailabilityRequest(
                ingredients=[
                    RecipeIngredient(
                        name="chicken stock", quantity=3.2, unit="cup"
                    )
                ]
            )
        )

        self.assertEqual(4, result.items[0].requested_quantity)
        self.assertEqual(0, result.items[0].available_quantity)
        self.assertEqual("PAN-VEGSTOCK", result.substitutes[0].product.sku)
        self.assertTrue(result.model_used)

    async def test_rejects_ungrounded_substitute_sku(self) -> None:
        foundry = FakeFoundry(
            {
                "substitutions": [
                    {
                        "requested": "chicken stock",
                        "sku": "INVENTED",
                    }
                ]
            }
        )
        service = AvailabilityService(
            self.settings, FakeInventory(self.substitute), foundry
        )

        with self.assertRaisesRegex(RuntimeError, "ungrounded SKU"):
            await service.handle(
                AvailabilityRequest(
                    ingredients=[
                        RecipeIngredient(
                            name="chicken stock", quantity=1, unit="cup"
                        )
                    ]
                )
            )

    async def test_rejects_candidate_with_insufficient_quantity(self) -> None:
        insufficient = self.substitute.model_copy(
            update={
                "product": self.substitute.product.model_copy(
                    update={"quantity": 1}
                )
            }
        )
        foundry = FakeFoundry({"substitutions": []})
        service = AvailabilityService(
            self.settings, FakeInventory(insufficient), foundry
        )

        result = await service.handle(
            AvailabilityRequest(
                ingredients=[
                    RecipeIngredient(
                        name="chicken stock", quantity=4, unit="cup"
                    )
                ]
            )
        )

        self.assertEqual([], result.substitutes)
        self.assertEqual([], foundry.requests)


class _FakeConcierge:
    async def handle(self, _: Any) -> ConciergeResult:
        return ConciergeResult(
            intent="meal_plan",
            search_terms=["quick"],
            dietary_preferences=["vegan"],
            excluded_ingredients=["peanuts"],
        )


class _FakeTransport:
    def __init__(self) -> None:
        self.plan_request: MealPlanRequest | None = None
        self.availability_request: AvailabilityRequest | None = None

    async def meal_plan(self, request: MealPlanRequest) -> Any:
        from aks_agents.contracts import MealPlanResult

        self.plan_request = request
        return MealPlanResult(recipes=[], rationale="None")

    async def availability(self, request: AvailabilityRequest) -> Any:
        from aks_agents.contracts import AvailabilityResult

        self.availability_request = request
        return AvailabilityResult(items=[], all_available=True)


class OrchestrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_propagates_constraints_to_downstream_agents(self) -> None:
        transport = _FakeTransport()
        orchestrator = object.__new__(Orchestrator)
        orchestrator._concierge = _FakeConcierge()
        orchestrator._http = transport
        orchestrator._planner = None
        orchestrator._availability = None

        await orchestrator.run(
            InteractionRequest(
                user_id="anonymous",
                message="quick vegan meal without peanuts",
                servings=4,
                store="store-1",
                budget=25,
            )
        )

        assert transport.plan_request
        assert transport.availability_request
        self.assertEqual(["peanuts"], transport.plan_request.excluded_ingredients)
        self.assertEqual(25, transport.plan_request.budget)
        self.assertEqual("store-1", transport.availability_request.store)
        self.assertEqual(
            ["vegan"], transport.availability_request.dietary_preferences
        )


if __name__ == "__main__":
    unittest.main()

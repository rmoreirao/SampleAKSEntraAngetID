from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, Field, field_validator


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    service: str
    version: str = "0.1.0"


class Product(BaseModel):
    sku: str
    name: str
    category: str
    quantity: int = Field(ge=0)
    unit: str
    tags: list[str] = Field(default_factory=list)


class ProductAvailability(BaseModel):
    sku: str
    name: str
    requested_quantity: int = Field(ge=1)
    available_quantity: int = Field(ge=0)
    available: bool
    unit: str


class Substitute(BaseModel):
    requested: str
    product: Product
    reason: str


class RecipeIngredient(BaseModel):
    name: str
    quantity: float = Field(gt=0)
    unit: str


class Recipe(BaseModel):
    id: str
    name: str
    description: str
    servings: int = Field(gt=0)
    ingredients: list[RecipeIngredient]
    instructions: list[str]
    tags: list[str] = Field(default_factory=list)


class InteractionRequest(BaseModel):
    interaction_id: UUID = Field(default_factory=uuid4)
    user_id: str = Field(min_length=1, max_length=200)
    message: str = Field(min_length=1, max_length=4000)
    servings: int = Field(default=2, ge=1, le=20)
    dietary_preferences: list[str] = Field(default_factory=list)
    store: str = "default"
    budget: float | None = Field(default=None, gt=0)


class ChatRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    store: str = Field(default="default", min_length=1, max_length=200)
    diet: list[str] = Field(default_factory=list)
    servings: int = Field(default=2, ge=1, le=20)
    budget: float | None = Field(default=None, gt=0)
    correlation_id: UUID = Field(default_factory=uuid4)

    @field_validator("diet", mode="before")
    @classmethod
    def normalize_diet(cls, value: Any) -> list[str]:
        if value is None or value == "":
            return []
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    def to_interaction(self) -> InteractionRequest:
        return InteractionRequest(
            interaction_id=self.correlation_id,
            user_id="anonymous",
            message=self.prompt,
            servings=self.servings,
            dietary_preferences=self.diet,
            store=self.store,
            budget=self.budget,
        )


class ConciergeRequest(BaseModel):
    message: str
    dietary_preferences: list[str] = Field(default_factory=list)


class ConciergeResult(BaseModel):
    intent: Literal["meal_plan", "inventory_query", "unknown"]
    search_terms: list[str]
    dietary_preferences: list[str]
    excluded_ingredients: list[str] = Field(default_factory=list)


class MealPlanRequest(BaseModel):
    search_terms: list[str]
    dietary_preferences: list[str] = Field(default_factory=list)
    excluded_ingredients: list[str] = Field(default_factory=list)
    servings: int = Field(default=2, ge=1, le=20)
    store: str = Field(default="default", min_length=1, max_length=200)
    budget: float | None = Field(default=None, gt=0)


class PlannedRecipe(BaseModel):
    recipe: Recipe
    scaled_ingredients: list[RecipeIngredient]


class MealPlanResult(BaseModel):
    recipes: list[PlannedRecipe]
    rationale: str
    grounding_source_ids: list[str] = Field(default_factory=list)
    model_used: bool = False


class AvailabilityRequest(BaseModel):
    ingredients: list[RecipeIngredient]
    dietary_preferences: list[str] = Field(default_factory=list)
    excluded_ingredients: list[str] = Field(default_factory=list)
    store: str = Field(default="default", min_length=1, max_length=200)


class AvailabilityResult(BaseModel):
    items: list[ProductAvailability]
    substitutes: list[Substitute] = Field(default_factory=list)
    all_available: bool
    as_of: datetime = Field(default_factory=lambda: datetime.now(UTC))
    model_used: bool = False


class InteractionResult(BaseModel):
    interaction_id: UUID
    concierge: ConciergeResult
    meal_plan: MealPlanResult
    availability: AvailabilityResult


class ChatAccepted(BaseModel):
    correlation_id: UUID
    status: Literal["accepted"] = "accepted"
    events_url: str


class UiIngredient(BaseModel):
    name: str
    quantity: str
    status: Literal["available", "unavailable", "substitute"]
    note: str | None = None
    substitute: str | None = None


class UiRecommendation(BaseModel):
    id: str
    title: str
    description: str
    prepMinutes: int = Field(ge=0)
    servings: int = Field(gt=0)
    estimatedCost: float = Field(ge=0)
    tags: list[str]
    ingredients: list[UiIngredient]
    citationIds: list[str]


class UiCitation(BaseModel):
    id: str
    title: str
    source: str
    url: str | None = None
    snippet: str | None = None


class UiChatResult(BaseModel):
    summary: str
    recommendations: list[UiRecommendation]
    citations: list[UiCitation]
    store: str
    updatedAt: datetime = Field(default_factory=lambda: datetime.now(UTC))


class TimelineEvent(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))
    kind: Literal["orchestration", "azure-uami", "agent-a2a", "agent-mcp"]
    source: str
    target: str
    operation: str
    duration_ms: int = Field(default=0, ge=0)
    status: Literal["running", "success", "error"]
    correlation_id: UUID
    result: UiChatResult | None = None
    detail: dict[str, Any] | None = None


class EventType(StrEnum):
    ACCEPTED = "interaction.accepted"
    CONCIERGE = "concierge.completed"
    RAG = "rag.completed"
    MEAL_REASONING = "meal_reasoning.completed"
    MEAL_PLAN = "meal_plan.completed"
    INVENTORY = "inventory.completed"
    AVAILABILITY_REASONING = "availability_reasoning.completed"
    AVAILABILITY = "availability.completed"
    COMPLETED = "interaction.completed"
    ERROR = "interaction.error"


class InteractionEvent(BaseModel):
    event_id: UUID = Field(default_factory=uuid4)
    interaction_id: UUID
    type: EventType
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))
    data: dict[str, Any] = Field(default_factory=dict)

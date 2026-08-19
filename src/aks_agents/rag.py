from __future__ import annotations

import asyncio
from typing import Protocol

from azure.core.credentials import TokenCredential
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient

from .contracts import Recipe
from .data_store import load_recipes
from .settings import Settings


class RecipeRetriever(Protocol):
    async def retrieve(
        self, search_terms: list[str], dietary_preferences: list[str], limit: int = 3
    ) -> list[Recipe]: ...


class LocalRecipeRetriever:
    def __init__(self, settings: Settings) -> None:
        self._recipes = load_recipes(settings)

    async def retrieve(
        self, search_terms: list[str], dietary_preferences: list[str], limit: int = 3
    ) -> list[Recipe]:
        terms = {value.casefold() for value in [*search_terms, *dietary_preferences] if value}
        ranked: list[tuple[int, Recipe]] = []
        for recipe in self._recipes:
            text = " ".join(
                [
                    recipe.name,
                    recipe.description,
                    *recipe.tags,
                    *(ingredient.name for ingredient in recipe.ingredients),
                ]
            ).casefold()
            if dietary_preferences and not all(
                preference.casefold() in recipe.tags for preference in dietary_preferences
            ):
                continue
            score = sum(term in text for term in terms)
            ranked.append((score, recipe))
        return [
            recipe
            for _, recipe in sorted(ranked, key=lambda row: (-row[0], row[1].name))[:limit]
        ]


class AzureSearchRecipeRetriever:
    def __init__(self, settings: Settings) -> None:
        settings.require_cloud_search()
        credential: TokenCredential = DefaultAzureCredential(
            managed_identity_client_id=settings.uami_client_id
        )
        self._client = SearchClient(
            endpoint=str(settings.azure_search_endpoint),
            index_name=settings.azure_search_index,
            credential=credential,
        )
        self._semantic_configuration = settings.azure_search_semantic_configuration

    async def retrieve(
        self, search_terms: list[str], dietary_preferences: list[str], limit: int = 3
    ) -> list[Recipe]:
        normalized_preferences = sorted(
            {preference.strip().casefold() for preference in dietary_preferences if preference.strip()}
        )
        query = " ".join([*search_terms, *normalized_preferences]) or "*"
        dietary_filter = " and ".join(
            f"tags/any(tag: tag eq '{preference.replace(chr(39), chr(39) * 2)}')"
            for preference in normalized_preferences
        )

        def search() -> list[Recipe]:
            kwargs: dict[str, object] = {"top": limit}
            if dietary_filter:
                kwargs["filter"] = dietary_filter
            if self._semantic_configuration:
                kwargs.update(
                    query_type="semantic",
                    semantic_configuration_name=self._semantic_configuration,
                )
            results = self._client.search(search_text=query, **kwargs)
            recipes: list[Recipe] = []
            for result in results:
                document = dict(result)
                document.pop("@search.score", None)
                document.pop("@search.reranker_score", None)
                document.pop("@search.captions", None)
                recipe = Recipe.model_validate(document)
                normalized_tags = {tag.casefold() for tag in recipe.tags}
                if all(preference in normalized_tags for preference in normalized_preferences):
                    recipes.append(recipe)
            return recipes

        return await asyncio.to_thread(search)


def create_recipe_retriever(settings: Settings) -> RecipeRetriever:
    if settings.retrieval_mode == "local":
        if not settings.development_mode:
            raise RuntimeError(
                "Local retrieval requires APP_DEVELOPMENT_MODE=true; no production fallback is used"
            )
        return LocalRecipeRetriever(settings)
    return AzureSearchRecipeRetriever(settings)

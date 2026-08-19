from __future__ import annotations

import json
from pathlib import Path

from pydantic import TypeAdapter

from .contracts import Product, ProductAvailability, Recipe, Substitute
from .settings import Settings


def _load_list(path: Path, model: type[Product] | type[Recipe]):
    if not path.is_file():
        raise RuntimeError(f"Seed data file not found: {path}")
    return TypeAdapter(list[model]).validate_python(json.loads(path.read_text("utf-8")))


class InventoryStore:
    def __init__(self, settings: Settings) -> None:
        self.products: list[Product] = _load_list(
            settings.data_directory / "inventory.json", Product
        )

    def search_products(self, query: str, limit: int = 10) -> list[Product]:
        terms = set(query.casefold().split())
        ranked: list[tuple[int, Product]] = []
        for product in self.products:
            text = " ".join([product.name, product.category, *product.tags]).casefold()
            score = sum(term in text for term in terms)
            if score:
                ranked.append((score, product))
        return [item for _, item in sorted(ranked, key=lambda row: (-row[0], row[1].name))[:limit]]

    def check_availability(self, sku_or_name: str, quantity: int = 1) -> ProductAvailability:
        key = sku_or_name.casefold()
        product = next(
            (
                item
                for item in self.products
                if item.sku.casefold() == key or item.name.casefold() == key
            ),
            None,
        )
        if product is None:
            return ProductAvailability(
                sku="unknown",
                name=sku_or_name,
                requested_quantity=quantity,
                available_quantity=0,
                available=False,
                unit="unknown",
            )
        return ProductAvailability(
            sku=product.sku,
            name=product.name,
            requested_quantity=quantity,
            available_quantity=product.quantity,
            available=product.quantity >= quantity,
            unit=product.unit,
        )

    def find_substitutes(self, sku_or_name: str, limit: int = 3) -> list[Substitute]:
        key = sku_or_name.casefold()
        requested = next(
            (
                item
                for item in self.products
                if item.sku.casefold() == key or item.name.casefold() == key
            ),
            None,
        )
        category = requested.category if requested else None
        candidates = [
            item
            for item in self.products
            if item.quantity > 0
            and item.name.casefold() != key
            and (
                (category and item.category == category)
                or bool(requested and set(item.tags).intersection(requested.tags))
                or (not requested and key in " ".join(item.tags).casefold())
            )
        ]
        return [
            Substitute(
                requested=sku_or_name,
                product=item,
                reason=f"Available alternative in {item.category}",
            )
            for item in sorted(candidates, key=lambda item: item.name)[:limit]
        ]


def load_recipes(settings: Settings) -> list[Recipe]:
    if not settings.development_mode:
        raise RuntimeError("Local recipes are available only in explicit development mode")
    return _load_list(settings.data_directory / "recipes.json", Recipe)

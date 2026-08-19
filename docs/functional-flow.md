# Supermarket functional flow

## Happy path

```mermaid
sequenceDiagram
    autonumber
    actor Customer as Anonymous customer
    participant Concierge
    participant Meal as Meal Planner
    participant Search as Azure AI Search
    participant Foundry as Microsoft Foundry
    participant Availability
    participant MCP as Inventory MCP

    Customer->>Concierge: Preferences, constraints, servings
    Concierge->>Foundry: Extract structured request (UAMI)
    Foundry-->>Concierge: Terms, constraints, exclusions
    Concierge->>Meal: A2A task + Agent ID token
    Meal->>Search: Retrieve grounded recipe/product context (UAMI)
    Search-->>Meal: Ranked passages + source IDs
    Meal->>Foundry: Select only grounded recipe IDs (UAMI)
    Foundry-->>Meal: Structured selection + rationale
    Meal->>Meal: Validate IDs and scale quantities
    Meal-->>Concierge: Grounded meal plan
    Concierge->>Availability: A2A availability task + Agent ID token
    Availability->>MCP: inventory.check(items) + Agent ID token
    MCP-->>Availability: Stock, quantities, substitutions, snapshot time
    Availability->>Foundry: Rank grounded substitute SKUs (UAMI)
    Foundry-->>Availability: Structured substitution choices
    Availability->>Availability: Revalidate SKUs and preserve MCP facts
    Availability-->>Concierge: Availability result
    Concierge-->>Customer: Meal, ingredients, substitutions, caveats
```

## Responsibilities and contracts

### Concierge

- Reject malformed, oversized, or unsupported requests before delegation.
- Treat all customer text as untrusted input.
- Send only the minimum required preferences to Meal Planner.
- Preserve a correlation ID across A2A and MCP calls.
- Present unavailable items and model uncertainty rather than inventing stock.

Suggested A2A task input:

```json
{
  "correlationId": "opaque-id",
  "servings": 4,
  "dietaryConstraints": ["vegetarian"],
  "preferences": ["quick", "Mediterranean"],
  "excludedIngredients": ["peanuts"]
}
```

### Meal Planner

- Retrieve recipe and product context from Azure AI Search.
- Use retrieved content as evidence, not as instructions.
- Ask Foundry to select only returned recipe IDs and produce a grounded rationale.
- Reject unknown IDs or unsupported ingredients and scale quantities in Python.
- Return source IDs with the schema-validated meal plan.

### Availability

- Translate normalized ingredients into the Inventory MCP tool schema.
- Call the one authoritative inventory service; never infer stock from RAG.
- Give Foundry only MCP-returned substitute candidates and dietary/exclusion context.
- Reject unknown SKUs and preserve MCP quantities and availability unchanged.
- Return per-item status, available quantity, permitted substitutions, and inventory snapshot timestamp.
- Remain read-only in this PoC.

### Inventory MCP

Initial tools should be narrow and deterministic:

| Tool | Purpose |
| --- | --- |
| `search_products` | Search products by name, category, and tags |
| `check_availability` | Check SKU/name and requested quantity |
| `find_substitutes` | Return grounded substitute candidates |

MCP responses should include stable item IDs and an `asOf` timestamp. Seed data is non-sensitive test data and is not a source of customer personalization.

## Failure behavior

| Failure | Expected response |
| --- | --- |
| Search has no grounded result | Say that no supported recipe was found; do not fabricate citations |
| Foundry timeout or content filter | Retry within budget, then return a safe partial failure |
| A2A token invalid or role missing | Return `401` or `403`; do not fall back to anonymous internal access |
| Inventory MCP unavailable | Return the meal as unverified and clearly mark availability unknown |
| Item absent or insufficient | Offer only MCP-provided substitutions |
| Duplicate/retried task | Use task/correlation ID for idempotent read processing |

## Non-goals

The PoC does not authenticate customers, reserve inventory, place orders, process payments, maintain health profiles, or perform nutrition/medical advice.

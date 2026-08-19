# Editable diagram assets

Open these editable sources with the Microsoft-hosted Excalidraw instance at [aka.ms/excalidraw](https://aka.ms/excalidraw):

| Source | Purpose |
| --- | --- |
| [solution-architecture.excalidraw](solution-architecture.excalidraw) | Public AKS PoC, agent chain, Foundry/Search, Agent ID, authentication options, and governance |
| [identity-flow.excalidraw](identity-flow.excalidraw) | ServiceAccount → UAMI → blueprint → Agent ID, Azure RBAC, and A2A/MCP app-role authorization |

The Mermaid diagrams remain convenient text-based views. The `.excalidraw` files are the editable visual sources of truth.

No SVG files are checked in because an authoritative export was not produced. If static assets are added later:

1. Export them from the reviewed `.excalidraw` source rather than hand-authoring generated markup.
2. Use Azure Architecture icons only under their applicable Microsoft terms.
3. Remove secrets, tenant/resource identifiers, and environment-specific hostnames.
4. Add accessible titles/descriptions and verify readability in light and dark GitHub themes.

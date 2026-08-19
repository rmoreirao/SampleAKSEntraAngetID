# Market & Table frontend

React, TypeScript, and Vite frontend for the Meal Planning & Availability Assistant.

```powershell
Copy-Item .env.example .env.local
npm install
npm run dev
```

The UI ships with no seeded data. On first load the results area and the activity
timeline show empty states, and a plan only appears once the backend returns one —
so nothing on screen is ever a placeholder pretending to be a result. Run the
web-api alongside `npm run dev` to see a populated plan.

There is a single light theme. Display, body, and data typefaces are bundled from
`@fontsource` at build time, so the container makes no external font requests.

Set `VITE_API_BASE_URL` to the web-api origin (port `8000` locally). The app calls:

- `POST /api/chat` with the client-generated `correlation_id`
- The `202 Accepted` response is `{ correlation_id, status, events_url }`
- The UI opens `events_url` as an anonymous `EventSource`
- SSE events contain `id`, `timestamp`, `kind`, `source`, `target`, `operation`,
  `duration_ms`, `status`, `correlation_id`, and an optional `result`
- A `completed` event supplies the final `result` meal plan; an `error` event
  ends the request with a failure message

The remaining service ports and server-side environment variables are:

| Service | Port | Environment variable |
| --- | ---: | --- |
| concierge | 8001 | `CONCIERGE_URL` |
| meal-planner | 8002 | `MEAL_PLANNER_URL` |
| availability | 8003 | `AVAILABILITY_URL` |
| inventory-mcp | 8004 | `INVENTORY_MCP_URL` |

All HTTP services expose `GET /healthz`.

Validation commands:

```powershell
npm run typecheck
npm run build
```

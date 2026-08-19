import type { InteractionEvent, MealPlanResponse } from "./types";

const baseUrl = (import.meta.env.VITE_API_BASE_URL ?? "").replace(/\/$/, "");

function apiUrl(path: string): string {
  return `${baseUrl}${path}`;
}

function resolveApiUrl(url: string): string {
  if (/^https?:\/\//i.test(url)) return url;
  return apiUrl(url.startsWith("/") ? url : `/${url}`);
}

export interface MealPlanRequest {
  prompt: string;
  store?: string;
  diet?: string;
  servings?: number;
  budget?: number;
  correlationId: string;
}

export interface ChatAccepted {
  correlation_id: string;
  status: string;
  events_url: string;
}

export async function requestMealPlan(
  request: MealPlanRequest,
  signal?: AbortSignal,
): Promise<ChatAccepted> {
  const response = await fetch(apiUrl("/api/chat"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-Correlation-ID": request.correlationId,
    },
    body: JSON.stringify({
      prompt: request.prompt,
      store: request.store,
      diet: request.diet,
      servings: request.servings,
      budget: request.budget,
      correlation_id: request.correlationId,
    }),
    signal,
  });

  if (response.status !== 202) {
    throw new Error(`Meal planning service returned ${response.status}; expected 202.`);
  }

  const accepted = (await response.json()) as Partial<ChatAccepted>;
  if (
    typeof accepted.correlation_id !== "string" ||
    typeof accepted.status !== "string" ||
    typeof accepted.events_url !== "string"
  ) {
    throw new Error("Meal planning service returned an invalid acceptance response.");
  }
  return accepted as ChatAccepted;
}

function isCallKind(value: unknown): value is InteractionEvent["kind"] {
  return (
    value === "orchestration" ||
    value === "azure-uami" ||
    value === "agent-a2a" ||
    value === "agent-mcp"
  );
}

function isCallStatus(value: unknown): value is InteractionEvent["status"] {
  return (
    value === "running" ||
    value === "success" ||
    value === "error"
  );
}

function isMealPlanResponse(value: unknown): value is MealPlanResponse {
  if (!value || typeof value !== "object") return false;
  const result = value as Partial<MealPlanResponse>;
  return (
    typeof result.summary === "string" &&
    Array.isArray(result.recommendations) &&
    Array.isArray(result.citations)
  );
}

function parseInteraction(data: string): InteractionEvent | null {
  try {
    const raw = JSON.parse(data) as Record<string, unknown>;
    const kind = raw.kind ?? raw.callType ?? raw.call_type;
    const status = raw.status;
    const correlationId = raw.correlationId ?? raw.correlation_id;
    const durationMs = raw.durationMs ?? raw.duration_ms;
    if (
      typeof raw.id !== "string" ||
      typeof raw.source !== "string" ||
      typeof raw.target !== "string" ||
      typeof raw.operation !== "string" ||
      typeof correlationId !== "string" ||
      !isCallKind(kind) ||
      !isCallStatus(status)
    ) {
      return null;
    }

    return {
      id: raw.id,
      timestamp: typeof raw.timestamp === "string" ? raw.timestamp : new Date().toISOString(),
      kind,
      source: raw.source,
      target: raw.target,
      operation: raw.operation,
      durationMs: typeof durationMs === "number" ? durationMs : undefined,
      status,
      correlationId,
      result: isMealPlanResponse(raw.result) ? raw.result : undefined,
    };
  } catch {
    return null;
  }
}

export function subscribeToInteractions(
  eventsUrl: string,
  onEvent: (event: InteractionEvent) => void,
  onConnectionChange: (connected: boolean) => void,
): () => void {
  const stream = new EventSource(resolveApiUrl(eventsUrl));

  stream.onopen = () => onConnectionChange(true);
  const handleMessage = (message: MessageEvent<string>) => {
    const event = parseInteraction(message.data);
    if (event) onEvent(event);
  };
  stream.onmessage = handleMessage;
  stream.addEventListener("interaction", handleMessage as EventListener);
  stream.onerror = () => onConnectionChange(false);

  return () => stream.close();
}

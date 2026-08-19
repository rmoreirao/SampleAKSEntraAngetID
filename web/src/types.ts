export type AvailabilityStatus = "available" | "low" | "substitute" | "unavailable";

export interface Ingredient {
  name: string;
  quantity: string;
  status: AvailabilityStatus;
  note?: string;
  substitute?: string;
}

export interface Citation {
  id: string;
  title: string;
  source: string;
  url?: string;
  snippet?: string;
}

export interface Recommendation {
  id: string;
  title: string;
  description: string;
  prepMinutes: number;
  servings: number;
  estimatedCost: number;
  tags: string[];
  ingredients: Ingredient[];
  citationIds: string[];
}

export interface MealPlanResponse {
  summary: string;
  recommendations: Recommendation[];
  citations: Citation[];
  store?: string;
  updatedAt?: string;
}

export type CallKind = "orchestration" | "azure-uami" | "agent-a2a" | "agent-mcp";
export type CallStatus = "running" | "success" | "error";

export interface InteractionEvent {
  id: string;
  timestamp: string;
  kind: CallKind;
  source: string;
  target: string;
  operation: string;
  durationMs?: number;
  status: CallStatus;
  correlationId: string;
  result?: MealPlanResponse;
}

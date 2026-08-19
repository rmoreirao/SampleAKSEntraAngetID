import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowRight,
  Bot,
  Check,
  CheckCircle2,
  ChefHat,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  ExternalLink,
  Leaf,
  LoaderCircle,
  MapPin,
  RefreshCw,
  Search,
  ShieldCheck,
  ShoppingBasket,
  Sparkles,
  TriangleAlert,
  Users,
  XCircle,
  Zap,
} from "lucide-react";
import { requestMealPlan, subscribeToInteractions } from "./api";
import type {
  AvailabilityStatus,
  InteractionEvent,
  MealPlanResponse,
  Recommendation,
} from "./types";

const samplePrompts = [
  "Three quick family dinners that reuse ingredients",
  "A high-protein vegetarian plan for busy weeknights",
  "Budget-friendly meals using seasonal vegetables",
];

const diets = ["No preference", "Vegetarian", "Vegan", "Gluten-free", "Dairy-free", "High protein"];

const availabilityLabels: Record<AvailabilityStatus, string> = {
  available: "In stock",
  low: "Low stock",
  substitute: "Swap found",
  unavailable: "Unavailable",
};

type RunStatus = "idle" | "planning" | "streaming" | "ready";

const runStatusLabels: Record<RunStatus, string> = {
  idle: "Ready",
  planning: "Planning",
  streaming: "Streaming",
  ready: "Plan ready",
};

function createCorrelationId(): string {
  return globalThis.crypto?.randomUUID?.() ??
    "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (character) => {
      const random = Math.floor(Math.random() * 16);
      const value = character === "x" ? random : (random & 0x3) | 0x8;
      return value.toString(16);
    });
}

function formatCurrency(value: number): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(value);
}

function AvailabilityBadge({ status }: { status: AvailabilityStatus }) {
  return <span className={`availability-badge availability-${status}`}>{availabilityLabels[status]}</span>;
}

function StockStrip({ recommendation }: { recommendation: Recommendation }) {
  const inStock = recommendation.ingredients.filter(
    (ingredient) => ingredient.status === "available",
  ).length;
  const total = recommendation.ingredients.length;

  return (
    <>
      <div
        className="stock-segments"
        role="img"
        aria-label={`${inStock} of ${total} ingredients in stock`}
      >
        {recommendation.ingredients.map((ingredient, index) => (
          <span
            key={ingredient.name}
            className={`stock-segment availability-${ingredient.status}`}
            style={{ ["--segment" as string]: index }}
            title={`${ingredient.name} — ${availabilityLabels[ingredient.status]}`}
          />
        ))}
      </div>
      <p className="stock-caption">
        <strong>{inStock}</strong> of {total} in stock
      </p>
    </>
  );
}

function RecommendationCard({
  recommendation,
  index,
  selected,
  onSelect,
}: {
  recommendation: Recommendation;
  index: number;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <article
      className={`shelf-label ${selected ? "is-selected" : ""}`}
      style={{ ["--card" as string]: index }}
    >
      <header className="shelf-tags">
        {recommendation.tags.slice(0, 3).map((tag) => (
          <span className="tag" key={tag}>{tag}</span>
        ))}
      </header>
      <div className="shelf-body">
        <h3>{recommendation.title}</h3>
        <p>{recommendation.description}</p>
        <dl className="meal-stats">
          <div>
            <dt><Clock3 size={14} aria-hidden="true" /> Prep</dt>
            <dd>{recommendation.prepMinutes} min</dd>
          </div>
          <div>
            <dt><Users size={14} aria-hidden="true" /> Serves</dt>
            <dd>{recommendation.servings}</dd>
          </div>
          <div className="meal-price">
            <dt className="sr-only">Estimated cost</dt>
            <dd>{formatCurrency(recommendation.estimatedCost)}</dd>
          </div>
        </dl>
      </div>
      <footer className="shelf-footer">
        <StockStrip recommendation={recommendation} />
        <div className="shelf-actions">
          <button className="text-button" type="button" onClick={onSelect} aria-pressed={selected}>
            {selected ? "Viewing ingredients" : "Check ingredients"}
            <ChevronRight size={16} aria-hidden="true" />
          </button>
        </div>
      </footer>
    </article>
  );
}

function PlanSkeleton() {
  return (
    <div className="recommendation-grid" aria-hidden="true">
      {[0, 1, 2].map((index) => (
        <div className="shelf-label is-skeleton" key={index} style={{ ["--card" as string]: index }}>
          <header className="shelf-tags"><span className="skeleton-chip" /><span className="skeleton-chip" /></header>
          <div className="shelf-body">
            <span className="skeleton-line wide" />
            <span className="skeleton-line" />
            <span className="skeleton-line short" />
          </div>
          <footer className="shelf-footer"><span className="skeleton-line strip" /></footer>
        </div>
      ))}
    </div>
  );
}

function EmptyBoard() {
  return (
    <div className="empty-board">
      <span className="empty-mark" aria-hidden="true"><ShoppingBasket size={26} strokeWidth={1.6} /></span>
      <h3>Nothing on the board yet</h3>
      <p>
        Describe the week you want to cook. Three dinners appear here with a stock strip for every
        ingredient and the sources behind each recipe.
      </p>
      <ul className="empty-legend">
        <li><span className="availability-available" /> In stock</li>
        <li><span className="availability-low" /> Low stock</li>
        <li><span className="availability-substitute" /> Swap found</li>
        <li><span className="availability-unavailable" /> Unavailable</li>
      </ul>
    </div>
  );
}

function IngredientPanel({ recommendation }: { recommendation?: Recommendation }) {
  if (!recommendation) return null;

  return (
    <section className="detail-card" aria-labelledby="ingredient-title">
      <div className="section-heading compact">
        <div>
          <span className="eyebrow"><ShoppingBasket size={14} aria-hidden="true" /> Store check</span>
          <h2 id="ingredient-title">Ingredient availability</h2>
        </div>
      </div>
      <p className="detail-intro">For <strong>{recommendation.title}</strong></p>
      <ul className="ingredient-list">
        {recommendation.ingredients.map((ingredient) => (
          <li key={ingredient.name}>
            <div className={`ingredient-check availability-${ingredient.status}`} aria-hidden="true">
              {ingredient.status === "unavailable" ? <XCircle size={17} /> : <Check size={17} />}
            </div>
            <div className="ingredient-name">
              <strong>{ingredient.name}</strong>
              <span>{ingredient.quantity}</span>
              {ingredient.note && <small>{ingredient.note}</small>}
              {ingredient.substitute && (
                <small className="substitution">Use instead: {ingredient.substitute}</small>
              )}
            </div>
            <AvailabilityBadge status={ingredient.status} />
          </li>
        ))}
      </ul>
    </section>
  );
}

function SourcesPanel({ plan }: { plan: MealPlanResponse }) {
  const [expanded, setExpanded] = useState(false);
  const sources = expanded ? plan.citations : plan.citations.slice(0, 3);

  return (
    <section className="detail-card" id="sources" aria-labelledby="sources-title">
      <div className="section-heading compact">
        <div>
          <span className="eyebrow"><Search size={14} aria-hidden="true" /> Grounded answer</span>
          <h2 id="sources-title">Sources &amp; citations</h2>
        </div>
        <span className="source-count">{plan.citations.length} sources</span>
      </div>
      <ol className="source-list">
        {sources.map((citation, index) => (
          <li key={citation.id}>
            <span className="citation-index">{index + 1}</span>
            <div>
              <strong>{citation.title}</strong>
              <span>{citation.source}</span>
              {citation.snippet && <p>{citation.snippet}</p>}
            </div>
            {citation.url && (
              <a href={citation.url} target="_blank" rel="noreferrer" aria-label={`Open ${citation.title}`}>
                <ExternalLink size={16} />
              </a>
            )}
          </li>
        ))}
      </ol>
      {plan.citations.length > 3 && (
        <button className="text-button" type="button" onClick={() => setExpanded((value) => !value)}>
          {expanded ? "Show fewer sources" : `Show all ${plan.citations.length} sources`}
          <ChevronRight className={expanded ? "rotate" : ""} size={16} aria-hidden="true" />
        </button>
      )}
    </section>
  );
}

const timelineLabels: Record<InteractionEvent["kind"], { title: string; icon: React.ReactNode }> = {
  orchestration: { title: "Workflow", icon: <RefreshCw size={14} /> },
  "azure-uami": { title: "UAMI · Azure", icon: <ShieldCheck size={14} /> },
  "agent-a2a": { title: "Agent ID · A2A", icon: <Bot size={14} /> },
  "agent-mcp": { title: "Agent ID · MCP", icon: <Zap size={14} /> },
};

function Timeline({ events, connected }: { events: InteractionEvent[]; connected: boolean }) {
  return (
    <aside className="timeline-panel" id="activity" aria-labelledby="timeline-title">
      <div className="timeline-header">
        <div>
          <span className="eyebrow"><Sparkles size={14} aria-hidden="true" /> Orchestration</span>
          <h2 id="timeline-title">Activity</h2>
        </div>
        <span className={`connection ${connected ? "connected" : events.length > 0 ? "complete" : ""}`}>
          <span /> {connected ? "Streaming" : events.length > 0 ? "Complete" : "Idle"}
        </span>
      </div>
      <div className="timeline-legend">
        <span className="legend-uami"><span /> UAMI Azure call</span>
        <span className="legend-agent"><span /> Agent ID call</span>
      </div>
      <div className="timeline-list" aria-live="polite">
        {events.length === 0 ? (
          <div className="timeline-empty">
            <p>No calls yet.</p>
            <p>Agent and Azure calls appear here as your plan is built.</p>
          </div>
        ) : (
          events.map((event) => (
            <article className={`timeline-event kind-${event.kind}`} key={event.id}>
              <div className="timeline-rail">
                <span className="timeline-dot" />
              </div>
              <div className="event-card">
                <div className="event-topline">
                  <span className={`call-kind call-${event.kind}`}>
                    {timelineLabels[event.kind].icon} {timelineLabels[event.kind].title}
                  </span>
                  <span className={`event-status status-${event.status}`}>{event.status}</span>
                </div>
                <strong className="event-operation">{event.operation}</strong>
                <div className="route">
                  <span>{event.source}</span><ArrowRight size={13} aria-hidden="true" /><span>{event.target}</span>
                </div>
                <div className="event-meta">
                  <span>{event.durationMs === undefined ? "in progress" : `${event.durationMs} ms`}</span>
                  <span title={event.correlationId}>{event.correlationId.slice(0, 8)}</span>
                  <time dateTime={event.timestamp}>
                    {new Date(event.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}
                  </time>
                </div>
              </div>
            </article>
          ))
        )}
      </div>
      <div className="timeline-footer">
        <ShieldCheck size={15} aria-hidden="true" />
        <span>Operational metadata only. Credentials are never shown here.</span>
      </div>
    </aside>
  );
}

export default function App() {
  const [prompt, setPrompt] = useState("");
  const [store, setStore] = useState("");
  const [diet, setDiet] = useState("No preference");
  const [servings, setServings] = useState("4");
  const [budget, setBudget] = useState("60");
  const [plan, setPlan] = useState<MealPlanResponse | null>(null);
  const [selectedId, setSelectedId] = useState("");
  const [events, setEvents] = useState<InteractionEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [connected, setConnected] = useState(false);
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);
  const stopStream = useRef<(() => void) | null>(null);
  const requestController = useRef<AbortController | null>(null);

  useEffect(() => () => {
    stopStream.current?.();
    requestController.current?.abort();
  }, []);

  const selectedRecommendation = useMemo(
    () => plan?.recommendations.find((item) => item.id === selectedId) ?? plan?.recommendations[0],
    [plan, selectedId],
  );

  const runStatus: RunStatus = loading ? (connected ? "streaming" : "planning") : plan ? "ready" : "idle";

  function addEvent(event: InteractionEvent) {
    setEvents((current) => {
      const existing = current.findIndex((item) => item.id === event.id);
      if (existing === -1) return [...current, event];
      return current.map((item, index) => (index === existing ? event : item));
    });
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!prompt.trim() || loading) return;

    requestController.current?.abort();
    stopStream.current?.();
    const controller = new AbortController();
    requestController.current = controller;
    const correlationId = createCorrelationId();

    setLoading(true);
    setMessage(null);
    setEvents([]);
    setPlan(null);
    setSelectedId("");
    setConnected(false);
    try {
      const accepted = await requestMealPlan(
        {
          prompt: prompt.trim(),
          store: store.trim() || undefined,
          diet: diet === "No preference" ? undefined : diet,
          servings: servings ? Number(servings) : undefined,
          budget: budget ? Number(budget) : undefined,
          correlationId,
        },
        controller.signal,
      );
      if (controller.signal.aborted) return;

      stopStream.current = subscribeToInteractions(
        accepted.events_url,
        (interaction) => {
          addEvent(interaction);
          if (interaction.status === "success" && interaction.result) {
            stopStream.current?.();
            setConnected(false);
            setLoading(false);
            setPlan(interaction.result);
            setSelectedId(interaction.result.recommendations[0]?.id ?? "");
            setMessage({ tone: "success", text: "Your plan is ready, checked against current stock." });
          } else if (interaction.status === "error") {
            stopStream.current?.();
            setConnected(false);
            setLoading(false);
            setMessage({ tone: "error", text: "Planning stopped before a plan was built. Adjust your request and try again." });
          }
        },
        setConnected,
      );
    } catch (error) {
      if (!(error instanceof DOMException && error.name === "AbortError")) {
        setMessage({ tone: "error", text: "The planning service didn't respond. Check that it's running, then try again." });
        setLoading(false);
      }
    }
  }

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Market and Table home">
          <span className="brand-mark"><Leaf size={19} /></span>
          <span>Market <i>&amp;</i> Table</span>
        </a>
        <nav aria-label="Primary navigation">
          <a href="#planner">Plan meals</a>
          <a href="#recommendations">Your plan</a>
          <a href="#activity">Activity</a>
        </nav>
        <div className="header-actions">
          <span className={`status-chip status-${runStatus}`}>
            <span aria-hidden="true" />
            {runStatusLabels[runStatus]}
          </span>
        </div>
      </header>

      <main id="top">
        <section className="hero" id="planner">
          <div className="hero-copy">
            <span className="eyebrow hero-eyebrow"><Sparkles size={14} aria-hidden="true" /> Only what the store actually has</span>
            <h1>Cook the week from <em>today&rsquo;s shelf</em></h1>
            <p>
              Say what you want to eat. We match it against trusted recipes, your budget, and live
              stock at your store &mdash; so every ingredient on the list is one you can buy tonight.
            </p>
          </div>

          <form className="planner-card" onSubmit={submit}>
            <label className="prompt-label" htmlFor="meal-prompt">Describe your ideal meal plan</label>
            <div className="prompt-box">
              <textarea
                id="meal-prompt"
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                rows={3}
                placeholder="Plan three healthy dinners for four people under $60, with one vegetarian option."
                required
              />
              <button className="primary-button" type="submit" disabled={loading}>
                {loading
                  ? <><LoaderCircle className="spin" size={17} aria-hidden="true" /> Planning</>
                  : <><Sparkles size={17} aria-hidden="true" /> Build my plan</>}
              </button>
            </div>
            <div className="preference-grid">
              <label>
                <span><MapPin size={14} aria-hidden="true" /> Preferred store</span>
                <input value={store} onChange={(event) => setStore(event.target.value)} placeholder="Any nearby store" />
              </label>
              <label>
                <span><Leaf size={14} aria-hidden="true" /> Dietary preference</span>
                <select value={diet} onChange={(event) => setDiet(event.target.value)}>
                  {diets.map((item) => <option key={item}>{item}</option>)}
                </select>
              </label>
              <label>
                <span><Users size={14} aria-hidden="true" /> Servings</span>
                <input type="number" min="1" max="20" value={servings} onChange={(event) => setServings(event.target.value)} />
              </label>
              <label>
                <span><CircleDollarSign size={14} aria-hidden="true" /> Budget</span>
                <div className="input-prefix">
                  <span aria-hidden="true">$</span>
                  <input aria-label="Budget in dollars" type="number" min="1" step="1" value={budget} onChange={(event) => setBudget(event.target.value)} />
                </div>
              </label>
            </div>
            <div className="sample-prompts">
              <span>Try an idea</span>
              <div>
                {samplePrompts.map((sample) => (
                  <button type="button" key={sample} onClick={() => setPrompt(sample)}>{sample}</button>
                ))}
              </div>
            </div>
          </form>
        </section>

        <div className="content-layout">
          <div className="results-column">
            {message && (
              <div className={`notice notice-${message.tone}`} role="status">
                {message.tone === "success" ? <CheckCircle2 size={17} aria-hidden="true" /> : <TriangleAlert size={17} aria-hidden="true" />}
                {message.text}
              </div>
            )}
            <section className="recommendations" id="recommendations" aria-labelledby="recommendations-title">
              <div className="section-heading">
                <div>
                  <span className="eyebrow"><ChefHat size={14} aria-hidden="true" /> Your tailored plan</span>
                  <h2 id="recommendations-title">This week&rsquo;s dinners</h2>
                  {plan?.summary && <p>{plan.summary}</p>}
                </div>
                {plan && (
                  <div className="store-stamp">
                    <span>{plan.store || store || "Nearby store"}</span>
                    <small>{plan.updatedAt ?? "Availability recently checked"}</small>
                  </div>
                )}
              </div>

              {loading && <PlanSkeleton />}
              {!loading && !plan && <EmptyBoard />}
              {!loading && plan && (
                <div className="recommendation-grid">
                  {plan.recommendations.map((recommendation, index) => (
                    <RecommendationCard
                      key={recommendation.id}
                      index={index}
                      recommendation={recommendation}
                      selected={recommendation.id === selectedRecommendation?.id}
                      onSelect={() => setSelectedId(recommendation.id)}
                    />
                  ))}
                </div>
              )}
            </section>

            {plan && (
              <div className="details-grid">
                <IngredientPanel recommendation={selectedRecommendation} />
                <SourcesPanel plan={plan} />
              </div>
            )}
          </div>
          <Timeline events={events} connected={connected} />
        </div>
      </main>

      <footer>
        <div className="brand footer-brand"><span className="brand-mark"><Leaf size={17} /></span><span>Market <i>&amp;</i> Table</span></div>
        <p>Smarter plans. Fewer substitutions. Less food waste.</p>
        <span>Availability and pricing may change before checkout.</span>
      </footer>
    </div>
  );
}

"""Model instances for every agent role, behind one shared request limiter (TDD §3, §12).

byLLM has no rate limiter and does not retry a 429, and `by m(temperature=...)` overwrites
m's call params, so roles that share an instance leak settings into each other's
concurrent calls (TDD §3, rules 1 to 3). Every provider request goes through
LimitedModel.model_call_no_stream: byLLM's parse retries, transient-error retries, ReAct
iterations, and compaction summaries all call it again.

Every role calls the same ordered chain of free models, CHAIN. agents/catalog.jac sets it
from OpenRouter's live free list at each run's preflight, and a model OpenRouter answers is
gone or no longer free is retired for the rest of the run, so later requests skip it instead
of spending a request on it first.
"""
import asyncio;
import from contextvars { ContextVar }
import logging;
import os;
import threading;
import time;
import from datetime { datetime, timezone }
import from importlib { import_module }
import httpx;
import from jaclang.byllm.lib { AuthenticationError, ConfigurationError, Model, ModelNotFoundError, RateLimitError }
import from jaclang.byllm.mtir { MTRuntime }
import from jaclang.byllm.types { CompletionResult }

"""Optional per-report ceiling, shared by its network tasks and including retries."""
obj RequestBudget {
    has remaining: int, deadline: float;
    has used: int = 0;

    def consume {
        if self.remaining <= 0 or time.monotonic() >= self.deadline {
            raise RuntimeError("Report model budget or deadline exhausted.");
        }
        self.remaining -= 1;
        self.used += 1;
    }
}

glob REQUEST_BUDGET: ContextVar[RequestBudget | None] = ContextVar("report_budget", `default=None);

glob REQUEST_KINDS: tuple[str, ...] = ("first_attempt", "parse_retry", "transient_retry", "fallback");

"""One provider dispatch's state, isolated across threads, async tasks and nested tools."""
obj RequestAttempt {
    has kind: str = "first_attempt",
        sent: int = 0;
}

glob _ATTEMPT: ContextVar[RequestAttempt | None] = ContextVar("parallax_request_attempt", `default=None);

def request_total(counts: dict[str, dict[str, int]]) -> int {
    return sum(sum(kinds.values()) for kinds in counts.values());
}

"""Preserve validation messages and their exception causes, including the first role's
failure when the low-temperature retry also fails. Never cap these diagnostic strings."""
def model_error(error: Exception, previous: str = "") -> str {
    parts: list[str] = [];
    seen: set[int] = set();
    current: BaseException | None = error;
    while current is not None and id(current) not in seen {
        seen.add(id(current));
        detail = f"{type(current).__name__}: {current}";
        if not parts or detail not in parts[-1] {
            parts.append(detail);
        }
        current = current.__cause__ or current.__context__;
    }
    if previous and previous not in "\n".join(parts) {
        parts.append(f"Previous role attempt: {previous}");
    }
    return "\nCaused by: ".join(parts);
}

# The vetted order, from the free-model spike of 2026-11-02 (docs/spikes/2026-11-02-free-models.md),
# rerun after Nemotron 3 Super left the free list: Nemotron 3.5 Super VL returned 11 of 12
# typed outputs on the first request with no provider errors. The fallback needed a parse retry
# on 8 of 12; it is a preview that OpenRouter lists until 2026-12-31. agents/catalog.jac checks
# both against the live free list at each run and fills in behind them.
glob PRIMARY_MODEL: str = "openrouter/nvidia/nemotron-3.5-super-vl:free";
glob FALLBACK_MODEL: str = "openrouter/dots-studio/dots-3-note-preview:free";
# OpenRouter's Free Models Router, the chain's last link: it picks some free model per request,
# so it is used only after every chosen model has failed (agents/catalog.jac).
glob ROUTER_MODEL: str = "openrouter/openrouter/free";
glob REQUESTS_PER_MINUTE: int = 18;
# Spike #12's slowest successful request took 153 s; LiteLLM's default would wait 600 s.
glob REQUEST_TIMEOUT_S: float = 180.0;
glob KILL_SWITCH_ENV: str = "TRADING_AGENT_DISABLE_MODELS";
# The account's free-model allowance per UTC day, after its one-time $10 credit purchase
# (TDD §12).
glob FREE_REQUESTS_PER_DAY: int = 1000;
glob OPENROUTER_API_BASE: str = "https://openrouter.ai/api/v1";
glob OPENROUTER_API_BASE_ENV: str = "OPENROUTER_API_BASE";

# OpenRouter answers with the model name minus its "openrouter/" prefix, so LiteLLM's cost
# lookup after every response fails to find a provider and prints a "Provider List" banner
# three or four times before swallowing the error; a 20-ticker pass printed 213. Errors still
# raise; only the banner goes. The import is dynamic because a static `import litellm` makes
# `jac check` analyze all of LiteLLM's source, which takes minutes.
with entry {
    import_module("litellm").suppress_debug_info = True;
}

"""Raised instead of a provider request while the kill switch is on."""
obj ModelsDisabledError(Exception) {}

def models_disabled -> bool {
    return os.environ.get(KILL_SWITCH_ENV, "").strip().lower() in ("1", "true", "yes");
}

glob LOG: logging.Logger = logging.getLogger("trading_agent.models");
# What OpenRouter says about a model that has left the free list or has no provider left
# (2026-11-02: "This model is unavailable for free"), besides byLLM's ModelNotFoundError.
glob GONE_MARKERS: tuple[str, ...] = ("unavailable for free", "No endpoints found", "is not a valid model");

"""True when `error` says the model is gone, not merely busy, so retrying it is a waste."""
def model_gone(error: Exception) -> bool {
    current: BaseException | None = error;
    seen: set[int] = set();
    while current is not None and id(current) not in seen {
        seen.add(id(current));
        if isinstance(current, ModelNotFoundError) or "NotFound" in type(current).__name__ {
            return True;
        }
        if any(marker in str(current) for marker in GONE_MARKERS) {
            return True;
        }
        current = current.__cause__ or current.__context__;
    }
    return False;
}

"""The free models every role calls, in order: a request goes to the first model in service,
then to each next one when it stays rate limited, fails, or hangs. A model OpenRouter says is
gone is retired until the next `reset`, at the next run's preflight. `routed` counts which
models answered through the Free Models Router, since its name says nothing about that."""
obj ModelChain {
    has models: list[str];
    has retired: dict[str, str] = {},
        routed: dict[str, int] = {},
        _lock: threading.Lock | None = None;

    def postinit {
        self._lock = threading.Lock();
    }

    """Use `models`, in order, and bring every retired model back."""
    def reset(models: list[str]) {
        if not models {
            raise ValueError("a model chain needs at least one model");
        }
        with self._lock {
            self.models = list(models);
            self.retired = {};
            self.routed = {};
        }
    }

    """Count an answer the router got from `answered_by`."""
    def note_routed(answered_by: str) {
        with self._lock {
            self.routed[answered_by] = self.routed.get(answered_by, 0) + 1;
        }
    }

    """The models in service, in order. When every model is retired, all of them, so a request
    still reaches a provider and fails with its own error rather than ours."""
    def live -> list[str] {
        with self._lock {
            found = [m for m in self.models if m not in self.retired];
            return found or list(self.models);
        }
    }

    """Take `model` out of service until the next reset."""
    def retire(model: str, reason: str) {
        with self._lock {
            if model in self.retired {
                return;
            }
            self.retired[model] = reason;
        }
        LOG.warning("model %s retired for this run: %s", model, reason);
    }
}

glob CHAIN: ModelChain = ModelChain(models=[PRIMARY_MODEL, FALLBACK_MODEL, ROUTER_MODEL]);

"""Paces requests evenly to at most `per_minute`, across every thread, and counts them per UTC
day, along with how many went to the fallback model."""
obj RequestLimiter {
    has per_minute: int;
    has sent: int = 0,
        fallbacks: int = 0,
        sent_by_day: dict[str, int] = {},
        by_role: dict[str, dict[str, int]] = {};
    has _lock: threading.Lock | None = None,
        _next_slot: float = 0.0;

    def postinit {
        self._lock = threading.Lock();
    }

    """Block until the next request may go out, then count it."""
    def acquire(role: str = "unknown", kind: str = "first_attempt") {
        if kind not in REQUEST_KINDS {
            raise ValueError(f"unknown model request kind: {kind}");
        }
        with self._lock {
            now = time.monotonic();
            if self._next_slot > now {
                time.sleep(self._next_slot - now);
                # Space from the real wake-up, which can be late, not the scheduled slot.
                now = time.monotonic();
            }
            budget = REQUEST_BUDGET.get();
            if budget is not None { budget.consume(); }
            self._next_slot = now + 60.0 / self.per_minute;
            self.sent += 1;
            day = datetime.now(timezone.utc).date().isoformat();
            self.sent_by_day[day] = self.sent_by_day.get(day, 0) + 1;
            counts = self.by_role.setdefault(role, {k: 0 for k in REQUEST_KINDS});
            counts[kind] += 1;
            if kind == "fallback" {
                self.fallbacks += 1;
            }
        }
    }

    """A detached, atomic snapshot; request kinds are mutually exclusive and sum to sent."""
    def snapshot -> dict[str, dict[str, int]] {
        with self._lock {
            return {role: dict(counts) for (role, counts) in self.by_role.items()};
        }
    }

    def since(before: dict[str, dict[str, int]]) -> dict[str, dict[str, int]] {
        after = self.snapshot();
        delta = {
            role: {kind: count - before.get(role, {}).get(kind, 0) for (kind, count) in counts.items()}
            for (role, counts) in after.items()
        };
        return {role: counts for (role, counts) in delta.items() if any(counts.values())};
    }
}

glob LIMITER: RequestLimiter = RequestLimiter(per_minute=REQUESTS_PER_MINUTE);

"""Free-model requests OpenRouter reports left for the UTC day, from GET /key, or None when
there is no key or no readable answer. The research exit run saw OpenRouter's `used` lag the
real count, so the Run Guard takes the lower of this and its own count (TDD §12). This is not
a model request and does not pass the limiter."""
def provider_requests_left -> int | None {
    key = os.environ.get("OPENROUTER_API_KEY", "");
    if not key {
        return None;
    }
    base = os.environ.get(OPENROUTER_API_BASE_ENV, OPENROUTER_API_BASE).rstrip("/");
    try {
        response = httpx.get(f"{base}/key", headers={"Authorization": f"Bearer {key}"}, timeout=30);
        response.raise_for_status();
        usage = (response.json().get("data") or {}).get("free_model_daily_requests") or {};
        left = usage.get("remaining");
        return int(left) if left is not None else None;
    } except Exception {
        return None;
    }
}

"""A byLLM model whose every provider request passes the limiter, backs off on 429, times
out, and falls back down its model chain when a model stays rate limited, is down, hangs, or
has left the free list. A model that has left the free list is retired for the run.

byLLM maps only 401, 429, and 404 to ByLLMError; a 5xx, an overloaded provider, a dropped
connection, or a timeout arrives as LiteLLM's own exception, so every error but an
authentication or configuration one falls back (#53)."""
obj LimitedModel(Model) {
    has limiter: RequestLimiter = LIMITER,
        role: str = "unknown",
        chain: ModelChain = CHAIN,
        max_429_retries: int = 3,
        backoff_s: float = 2.0,
        request_timeout_s: float = REQUEST_TIMEOUT_S,
        reasoning_effort: str = "low";

    # These hooks match the pinned Jac 0.37.12 runtime. Classify typed retries from
    # the actual retry hook, never by searching untrusted prompt text for a phrase.
    override def _typed_retry_reset(mt_run: MTRuntime, base_msgs: list[object], base_scaffolding: list[object], reason: str, output: str) {
        super._typed_retry_reset(mt_run, base_msgs, base_scaffolding, reason, output);
        setattr(mt_run, "_parallax_parse_retry", True);
    }

    override def dispatch_no_streaming(mt_run: MTRuntime) -> CompletionResult {
        state = RequestAttempt(kind="parse_retry" if getattr(mt_run, "_parallax_parse_retry", False) else "first_attempt");
        token = _ATTEMPT.set(state);
        try {
            return super.dispatch_no_streaming(mt_run);
        } finally {
            _ATTEMPT.reset(token);
        }
    }

    override async def adispatch_no_streaming(mt_run: MTRuntime) -> CompletionResult {
        state = RequestAttempt(kind="parse_retry" if getattr(mt_run, "_parallax_parse_retry", False) else "first_attempt");
        token = _ATTEMPT.set(state);
        try {
            return await super.adispatch_no_streaming(mt_run);
        } finally {
            _ATTEMPT.reset(token);
        }
    }

    override def model_call_no_stream(params: dict[str, object]) -> dict[str, object] {
        if models_disabled() {
            raise ModelsDisabledError(f"{KILL_SWITCH_ENV} is set; no model requests are made");
        }
        # Free reasoning models can default to a high effort, which makes every call slow; every
        # model in spike #12 accepted this setting.
        # Fallback must not mutate the primary model in byLLM's params: an outer
        # transport retry must start on the primary and retain its correct label.
        params = dict(params);
        params["extra_body"] = {
            **params.get("extra_body", {}),
            "reasoning": {"effort": self.reasoning_effort}
        };
        params["timeout"] = self.request_timeout_s;
        state = _ATTEMPT.get() or RequestAttempt();
        models = self.chain.live();
        for (index, model) in enumerate(models) {
            params["model"] = model;
            last = index == len(models) - 1;
            # The first model in service backs off on 429s; each later one gets one request.
            tries = self.max_429_retries + 1 if index == 0 else 1;
            for attempt in range(tries) {
                if index == 0 {
                    self.limiter.acquire(self.role, "transient_retry" if state.sent else state.kind);
                } else {
                    self.limiter.acquire(self.role, "fallback");
                }
                state.sent += 1;
                try {
                    response = super.model_call_no_stream(params);
                    if model == ROUTER_MODEL {
                        answered_by = str(getattr(response, "model", "") or "unknown");
                        self.chain.note_routed(answered_by);
                        LOG.warning("every chosen model failed; the Free Models Router answered with %s", answered_by);
                    }
                    return response;
                } except AuthenticationError {
                    raise;
                } except ConfigurationError {
                    raise;
                } except RateLimitError {
                    if attempt < tries - 1 {
                        time.sleep(self.backoff_s * (2 ** attempt));
                    } elif last {
                        raise;
                    }
                } except Exception as e {
                    if model_gone(e) {
                        self.chain.retire(model, model_error(e)[:300]);
                    }
                    if last {
                        raise;
                    }
                    break;
                }
            }
        }
        raise RuntimeError("the model chain is empty");
    }

    """Model's async path calls the provider directly, so route it through the sync one."""
    override async def model_call_no_stream_async(params: dict[str, object]) -> dict[str, object] {
        return await asyncio.to_thread(self.model_call_no_stream, params);
    }

    override def model_call_with_stream(_params: dict[str, object]) {
        raise NotImplementedError("Agents do not stream; streaming would bypass the limiter.");
    }

    override async def model_call_with_stream_async(_params: dict[str, object]) {
        raise NotImplementedError("Agents do not stream; streaming would bypass the limiter.");
    }
}

# One instance per role, so concurrent calls never share call params (TDD §3, rule 1).
glob research_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL, role="research");
glob specialist_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL, role="specialist");
glob arbiter_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL, role="arbiter");
glob orchestrator_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL, role="orchestrator");
glob retry_llm: LimitedModel = LimitedModel(model_name=PRIMARY_MODEL, role="retry");

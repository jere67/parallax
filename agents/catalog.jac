"""Which free models the agents call (TDD §12): a vetted order, checked against OpenRouter's
live free list at each run's preflight.

OpenRouter changes its free list without notice. Qwen3.8 27B left it before spike #12, and
Nemotron 3 Super, the primary model then, left it during the run of 2026-11-02, after which
every request spent one try on it before falling back. So the chain is not fixed in code:
`resolve_models` reads OpenRouter's public models list and keeps, in order, the vetted models
still listed free, then any other listed free model that can serve typed calls, as a last
resort. A model can still leave mid-run; LimitedModel retires it on its first "gone" answer.
Behind them all comes OpenRouter's Free Models Router, so a run whose every chosen model has
gone still gets answers.

Not every free model is safe to fall back to, so the last resort is filtered: a model must
take a JSON schema (`structured_outputs`, which byLLM's typed calls send) and tools (the
Orchestrator's loop), must not have passed its listed expiry, and must not be a kind spike #12
found answering wrongly: a content-safety classifier replies "safe" to any prompt, and
Inkling's free models answer only "agentic harnesses". Popularity is not a filter: it says
nothing about whether a model returns valid typed objects.

The router is last, never first, for the same reasons: it picks a model per request, so one
ticker's votes could come from different models, and spike #12 saw it send a plain prompt to
the content-safety classifier. Typed calls validate every answer, so a wrong pick fails as a
parse error rather than passing as a vote, and LimitedModel records which model answered.
"""
import logging;
import os;
import from datetime { date }
import httpx;
import from research.credentials { OPENROUTER_KEY, user_key }
import from agents.models { CHAIN, FALLBACK_MODEL, OPENROUTER_API_BASE, OPENROUTER_API_BASE_ENV, PRIMARY_MODEL, ROUTER_MODEL }

glob LOG: logging.Logger = logging.getLogger("trading_agent.models");

# The vetted order, best first, set in agents/models.jac from the free-model spike; rerun the
# spike before changing it.
glob PREFERRED_MODELS: list[str] = [PRIMARY_MODEL, FALLBACK_MODEL];
glob PREFIX: str = "openrouter/";
glob FREE_SUFFIX: str = ":free";
glob REQUIRED_PARAMETERS: tuple[str, ...] = ("structured_outputs", "tools");
glob EXCLUDED_MARKERS: tuple[str, ...] = ("content-safety", "thinkingmachines/inkling");
# More models than this only add requests a failing call spends before it gives up.
glob MAX_CHAIN: int = 3;

"""One model on OpenRouter's list, as much of it as the choice needs."""
obj ListedModel {
    has id: str,
        parameters: list[str] = [],
        expires: str = "";
}

"""OpenRouter's model list, or None when it cannot be read or there is no API key, since then
no model is called at all (and tests stay off the network). The list is public, so this sends
no key and spends no request from the free allowance."""
def listed_models -> list[ListedModel] | None {
    if not user_key(OPENROUTER_KEY) {
        return None;
    }
    base = os.environ.get(OPENROUTER_API_BASE_ENV, OPENROUTER_API_BASE).rstrip("/");
    try {
        response = httpx.get(f"{base}/models", timeout=30);
        response.raise_for_status();
        rows = response.json().get("data") or [];
        return [
            ListedModel(id=str(r["id"]), parameters=[str(p) for p in (r.get("supported_parameters") or [])], expires=str(r.get("expiration_date") or ""))
            for r in rows
            if isinstance(r, dict) and r.get("id")
        ];
    } except Exception as e {
        LOG.warning("OpenRouter's model list is unreadable, so the vetted models are used as they are: %s: %s", type(e).__name__, str(e)[:200]);
        return None;
    }
}

"""True when `m` is free on `today` and can serve every typed call and the tool loop."""
def usable(m: ListedModel, today: str) -> bool {
    if not m.id.endswith(FREE_SUFFIX) or any(marker in m.id for marker in EXCLUDED_MARKERS) {
        return False;
    }
    if m.expires and m.expires[:10] < today {
        return False;
    }
    return all(p in m.parameters for p in REQUIRED_PARAMETERS);
}

"""The models chosen for a run on `today`: the vetted models still usable, in their order, then
other usable free models in OpenRouter's order, at most MAX_CHAIN. With no list, the vetted
models as they are; with nothing usable listed, none. The router is added by `resolve_models`."""
def choose_models(listed: list[ListedModel] | None, today: str, preferred: list[str] = PREFERRED_MODELS) -> list[str] {
    if listed is None {
        return list(preferred)[:MAX_CHAIN];
    }
    ok = [m.id for m in listed if usable(m, today) and PREFIX + m.id != ROUTER_MODEL];
    chain = [p for p in preferred if p.removeprefix(PREFIX) in ok];
    chain.extend(PREFIX + i for i in ok if PREFIX + i not in chain);
    return chain[:MAX_CHAIN];
}

"""Set the shared model chain for the run on `today` and return it, with a note when it is not
the vetted order. The chain is the chosen models, then the router. With nothing usable listed,
the vetted models stay ahead of the router, and the note says why."""
def resolve_models(today: str = "") -> tuple[list[str], str] {
    day = today or date.today().isoformat();
    chain = choose_models(listed_models(), day);
    note = "";
    missing = [p.removeprefix(PREFIX) for p in PREFERRED_MODELS if p not in chain];
    if not chain {
        chain = list(PREFERRED_MODELS)[:MAX_CHAIN];
        note = "no free model on OpenRouter's list can serve typed calls; the vetted models are tried anyway, then the router";
    } elif missing {
        note = f"vetted models off the free list: {', '.join(missing)}; using {', '.join(m.removeprefix(PREFIX) for m in chain)}";
    }
    chain = chain + [ROUTER_MODEL];
    CHAIN.reset(chain);
    if note {
        LOG.warning("%s", note);
    }
    return (chain, note);
}

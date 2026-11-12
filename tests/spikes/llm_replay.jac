"""LLM replay (TDD §13, layer 1; docs/evaluation/llm-replay.md): the whole pipeline on past
mornings with history-only data, to check that it runs end to end and that its outputs are sane.

Five tickers, one sample per specialist (K = 1, the reduced configuration), over ten consecutive
trading days from REPLAY_FIRST. The tickers are the top five the real screen picked as of the
first day, kept for every day. Each day collects in replay mode (research/asof.jac), so every
source serves only what was published before 7:30 a.m. New York that day, then runs the
production research sub-agents, the specialist panel, the consensus rule, and the Arbiter
(run/research.jac, run/analysis.jac `analyze`), writing nothing to any graph. Each decision and
vote is then scored on its ten-session excess return over SPY (analysis/scoring.jac).

The days must fall after the models' training data: Nemotron 3.5 Super VL's foundation data
was collected through December 2025, and it was released on October 15, 2026.

It shares the team's free-model allowance with the live morning runs, so before every day it
reads OpenRouter's remaining free requests and waits unless the day's ceiling still leaves
KEEP_MORNING while the allowance has a weekday morning run ahead of it (from the UTC reset to
10:00 a.m. New York), or KEEP_OTHER after that morning's runs. It also slows Alpaca to 120 requests a minute and makes no data calls from
7:15 to 10:00 a.m. New York on weekdays, when the live runs collect. Progress is saved after
every day to REPLAY_STATE, so a stopped replay resumes where it left off.

    set -a && source .env && set +a
    TRADING_AGENT_RUN_LLM_REPLAY=1 REPLAY_STATE=/path/state.json \
        jac run --no-takeover tests/spikes/llm_replay.jac

REPLAY_MODE=score only scores what the state holds and writes docs/evaluation/llm-replay.json.
"""
import json;
import math;
import os;
import sys;
import time;
import from concurrent.futures { Future }
import from datetime { date, datetime, time as time_of_day, timedelta, timezone }
import from pathlib { Path }
import from zoneinfo { ZoneInfo }
import httpx;
import from agents.models { PRIMARY_MODEL, limiter_now }
import from agents.research { ResearchResult, macro_research, research }
import from analysis.consensus { sign }
import from analysis.policy { consensus_config }
import from analysis.scoring { BENCHMARK, excess_return, vote_window }
import from models.agents { Domain, Evidence, STANCE_SCORE }
import from models.policy { Policy }
import from research.alpaca { bars_final, daily_bars, market_calendar }
import from research.asof { decision_time, enter_as_of, leave_as_of }
import from research.briefs { macro_brief }
import from research.collector { run_budget }
import from research.screener { Pick, PickReason, ScreenConfig, Shortlist, gather, screen }
import from research.sources { SOURCES }
import from run.analysis { DecisionRule, TickerAnalysis, analyze }
import from run.research { Collection, PassConfig, PassStart, briefs_for, collect_shortlist, index_members }
import from run.workers { NETWORK }

glob RUN_ENV: str = "TRADING_AGENT_RUN_LLM_REPLAY";
glob FIRST_DAY: str = os.environ.get("REPLAY_FIRST", "2026-10-15");
glob DAYS: int = 10;
glob TICKERS: int = 5;
glob HORIZON: int = 10;
glob KEY_URL: str = "https://openrouter.ai/api/v1/key";
glob KEEP_MORNING: int = 650;
glob KEEP_OTHER: int = 100;
# The most one ticker can spend: three research reports, five votes, the Arbiter, and a parse
# retry or fallback on each, plus the day's macro report.
glob PER_TICKER_CEILING: int = 20;
glob ALPACA_PER_MINUTE: float = 120.0;
glob NEW_YORK: ZoneInfo = ZoneInfo("America/New_York");
glob OUT: Path = Path("docs/evaluation/llm-replay.json");
glob MODEL_CUTOFF: str = "2025-12";
glob CUTOFF_SOURCE: str = "NVIDIA's model card for Nemotron 3.5 Super VL (huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16): foundation data collection period 2013 to December 2025; listed on OpenRouter on October 15, 2026. The fallback, Dots3-Note Preview, was listed on August 14, 2026, so its data ends before then.";

# What each source the research pass reads does in a replay (research/asof.jac).
glob AUDIT: list[dict[str, str]] = [
    {"source": "Alpaca daily bars (stock, SPY, sector and bond ETFs)", "treatment": "bounded", "detail": "The query ends at the last session before the replayed day, and a series stamped at or after the decision time is dropped. Bars are split- and dividend-adjusted with today's factors, so price levels can differ from what was shown then; returns and indicators do not."},
    {"source": "Alpaca news (articles and the screen's counts)", "treatment": "bounded", "detail": "Every query ends at the decision time, and an article published at or after it is dropped."},
    {"source": "Finnhub company news", "treatment": "bounded", "detail": "Ends on the replayed day; an article published at or after the decision time is dropped."},
    {"source": "Finnhub key metrics", "treatment": "dropped", "detail": "Finnhub serves only today's snapshot, so it is not read; the Fundamentals brief records a gap and relies on SEC figures."},
    {"source": "Finnhub EPS surprises", "treatment": "stripped", "detail": "Finnhub dates a quarter by its end, not by when it was reported, so a quarter is kept only when an Item 2.02 earnings release filed after it ended and before the replayed day covers it."},
    {"source": "Finnhub recommendation trends", "treatment": "stripped", "detail": "The decision's own month is left out, since its counts kept changing after the decision; earlier months are kept."},
    {"source": "Finnhub earnings calendar (next release, and the screen's earnings flag)", "treatment": "stripped", "detail": "A release on or after the replayed day keeps its date and estimates but loses its actual EPS and revenue. The date shown is the one the calendar holds today, which can differ from the schedule known then."},
    {"source": "SEC submissions (8-K events, earnings release, Form 4)", "treatment": "bounded", "detail": "Only filings dated before the replayed day are listed, so every event, release, and insider trade read from them was public."},
    {"source": "SEC XBRL company facts", "treatment": "bounded", "detail": "A fact filed on or after the replayed day is left out, so neither a new quarter nor a later restatement leaks in."},
    {"source": "SEC 13F holdings", "treatment": "bounded", "detail": "Only filing windows that closed before the replayed day are used. SEC's listing does not give when each archive was posted, which the brief already notes as a gap."},
    {"source": "Wikipedia S&P 500 membership", "treatment": "bounded", "detail": "The members on the replayed day are rebuilt from today's list by undoing every later change in the historical-components table."},
    {"source": "Alpaca assets (the screen's tradability check)", "treatment": "dropped", "detail": "Alpaca lists only today's assets, so every member counts as tradable rather than drop one delisted since."},
    {"source": "Macro and regime inputs (SPY, sector and bond ETFs)", "treatment": "bounded", "detail": "Computed from the bounded daily bars."},
    {"source": "Market calendar", "treatment": "bounded", "detail": "The exchange schedule is published in advance, so the sessions around the day were known then."}
];

def say(text: str) {
    sys.stdout.write(f"{datetime.now(NEW_YORK).strftime('%m-%d %H:%M')} {text}\n");
    sys.stdout.flush();
}

# --- state ---------------------------------------------------------------------------------

def state_path -> Path {
    return Path(os.environ.get("REPLAY_STATE", "llm-replay-state.json"));
}

def load_state -> dict[str, any] {
    found = state_path();
    return json.loads(found.read_text()) if found.exists() else {"tickers": [], "days": [], "pairs": {}, "requests": 0, "seconds": 0.0, "screen_gaps": []};
}

def save_state(state: dict[str, any]) {
    target = state_path();
    temp = target.with_suffix(".tmp");
    temp.write_text(json.dumps(state, indent=1));
    temp.replace(target);
}

# --- pacing --------------------------------------------------------------------------------

def free_requests_left -> int | None {
    try {
        response = httpx.get(KEY_URL, headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}"}, timeout=30);
        data = response.json().get("data") or {};
        left = (data.get("free_model_daily_requests") or {}).get("remaining");
        return int(left) if isinstance(left, (int, float)) else None;
    } except Exception {
        return None;
    }
}

"""True while the free allowance `now` draws from still has a weekday morning run to serve. The
allowance resets at midnight UTC (7 or 8 p.m. New York), so from then until 10:00 a.m. the next
weekday morning's runs draw on it too."""
def live_morning(now: datetime) -> bool {
    day = now.astimezone(timezone.utc).date();
    return day.weekday() < 5 and now < datetime.combine(day, time_of_day(10, 0), NEW_YORK);
}

"""Sleep while the live runs collect (7:15 to 10:00 a.m. New York on weekdays)."""
def wait_for_quiet_sources {
    while True {
        local = datetime.now(NEW_YORK);
        minute = local.hour * 60 + local.minute;
        if local.weekday() >= 5 or minute < 7 * 60 + 15 or minute >= 10 * 60 {
            return;
        }
        say("live runs are collecting; waiting until 10:00 a.m. New York");
        time.sleep(300);
    }
}

"""Wait until spending `tickers` tickers' ceiling still leaves the live runs their share."""
def wait_for_budget(tickers: int = 1) {
    while True {
        wait_for_quiet_sources();
        now = datetime.now(timezone.utc);
        keep = KEEP_MORNING if live_morning(now) else KEEP_OTHER;
        left = free_requests_left();
        if left is not None and left - PER_TICKER_CEILING * tickers >= keep {
            return;
        }
        # Before a weekday's 10:00 the morning share frees up at 10:00; otherwise at the reset.
        say(f"{left} free requests left, keeping {keep} and needing {PER_TICKER_CEILING * tickers}; waiting");
        time.sleep(600);
    }
}

# --- the replay ----------------------------------------------------------------------------

"""The `DAYS` trading sessions from FIRST_DAY, and every session to two weeks past today, for
the time stops and the scoring windows."""
def replay_sessions -> tuple[list[str], list[str]] {
    today = date.today();
    sessions = [d.day for d in market_calendar((date.fromisoformat(FIRST_DAY) - timedelta(days=21)).isoformat(), (today + timedelta(days=14)).isoformat(), run_budget())];
    days = [s for s in sessions if s >= FIRST_DAY][:DAYS];
    return (days, sessions);
}

"""The screen's top `TICKERS` new picks as of the first day, from history-only data."""
def pick_tickers(day: str) -> tuple[list[dict[str, any]], list[str]] {
    budget = run_budget();
    gaps: list[str] = [];
    enter_as_of(decision_time(day));
    try {
        members = index_members(day, budget, gaps);
        (candidates, screen_gaps) = gather(day, members, budget);
        shortlist = screen(candidates, []);
    } finally {
        leave_as_of();
    }
    picks = [p for p in shortlist.picks if p.reason == PickReason.SCORE][:TICKERS];
    return ([{"symbol": p.symbol, "sector": p.sector, "score": p.score} for p in picks], gaps + screen_gaps);
}

"""Collect the fixed tickers for `day` with history-only data."""
def collect_day(day: str, tickers: list[dict[str, any]]) -> Collection {
    budget = run_budget();
    gaps: list[str] = [];
    at = decision_time(day);
    enter_as_of(at);
    try {
        members = index_members(day, budget, gaps);
        shortlist = Shortlist(picks=[Pick(symbol=t["symbol"], sector=t["sector"], reason=PickReason.SCORE, score=t["score"]) for t in tickers], scores=[], excluded={});
        return collect_shortlist(day, shortlist, members, PassConfig(), PassStart(now=at, budget=budget, gaps=gaps));
    } finally {
        leave_as_of();
    }
}

"""Evidence a report cites that is dated at or after the decision: a source the replay failed to
bound, or a date the model made up."""
def late(evidence: list[Evidence], at: datetime, label: str) -> list[str] {
    found: list[str] = [];
    for e in evidence {
        text = (e.published or "").strip();
        try {
            when = datetime.fromisoformat(text.replace("Z", "+00:00"));
            when = when if when.tzinfo is not None else when.replace(tzinfo=timezone.utc);
        } except ValueError {
            continue;
        }
        if when >= at {
            found.append(f"{label}: {text} {e.source_url}");
        }
    }
    return found;
}

def research_row(r: ResearchResult) -> dict[str, any] {
    return {"domain": r.domain.value, "complete": r.complete(), "model": r.model, "view": r.body.view.value, "confidence": r.body.confidence, "error": r.error};
}

"""One ticker's decision on `day` as a JSON row, scored later."""
def decision_row(day: str, a: TickerAnalysis, reports: dict[Domain, ResearchResult], macro_late: list[str], fetch_errors: list[str], requests: float, seconds: float) -> dict[str, any] {
    c = a.consensus;
    at = decision_time(day);
    late_evidence = list(macro_late);
    for (d, r) in reports.items() {
        late_evidence.extend(late(r.body.evidence, at, d.value));
    }
    ruling = a.ruling;
    errors = [f"fetch: {e}" for e in fetch_errors];
    errors.extend(f"research {d.value}: {r.error}" for (d, r) in reports.items() if r.error);
    errors.extend(f"vote {v.specialist.value}: {v.error}" for v in a.votes if v.error);
    if ruling is not None and ruling.error {
        errors.append(f"arbiter: {ruling.error}");
    }
    return {
        "day": day,
        "ticker": a.ticker,
        "action": a.action().value,
        "draft_action": a.draft.value,
        "score": c.score if c is not None else None,
        "agreement": c.agreement if c is not None else None,
        "ci_low": c.ci_low if c is not None else None,
        "ci_high": c.ci_high if c is not None else None,
        "arbiter_verdict": (ruling.verdict or ruling.action.value) if ruling is not None else "",
        "arbiter_model": ruling.model if ruling is not None else "",
        "downgrade_reason": ruling.downgrade_reason if ruling is not None else "",
        "forced_hold_reason": a.forced_hold_reason,
        "research": [research_row(r) for r in reports.values()],
        "votes": [
            {
                "specialist": v.specialist.value,
                "stance": v.vote.stance.value if v.vote is not None else None,
                "confidence": v.vote.confidence if v.vote is not None else None,
                "horizon_days": v.vote.horizon_days if v.vote is not None else None,
                "model": v.model,
                "valid": v.valid(),
                "excess_return": None,
                "hit": None
            }
            for v in a.votes
        ],
        "excess_return": None,
        "errors": errors,
        "late_evidence": late_evidence,
        "requests": requests,
        "seconds": seconds
    };
}

def replay(state: dict[str, any]) {
    for source in ["alpaca_data", "alpaca_trading"] {
        SOURCES[source].per_minute = ALPACA_PER_MINUTE;
    }
    wait_for_quiet_sources();
    (days, _sessions) = replay_sessions();
    state["days"] = days;
    if not state["tickers"] {
        (state["tickers"], state["screen_gaps"]) = pick_tickers(days[0]);
        save_state(state);
        say(f"screen as of {days[0]}: {', '.join(t['symbol'] for t in state['tickers'])}");
    }
    tickers = state["tickers"];
    rule = DecisionRule(config=consensus_config(Policy(), 1, 0));
    for day in days {
        todo = [t for t in tickers if f"{day}:{t['symbol']}" not in state["pairs"]];
        if not todo {
            continue;
        }
        wait_for_budget(len(todo));
        clock = time.monotonic();
        collection = collect_day(day, tickers);
        before = limiter_now().sent;
        macro = macro_research(macro_brief(day, collection.macro_inputs));
        state["requests"] += limiter_now().sent - before;
        macro_late = late(macro.body.evidence, decision_time(day), "macro");
        state["seconds"] += time.monotonic() - clock;
        say(f"{day}: collected in {time.monotonic() - clock:.0f}s, macro by {macro.model}");
        # As a morning run does: every ticker's research at once, then one panel pass over all of
        # them (`analyze` draws the votes in parallel).
        clock = time.monotonic();
        before = limiter_now().sent;
        running: dict[str, dict[Domain, Future[ResearchResult]]] = {};
        for t in todo {
            inputs = collection.inputs_for(t["symbol"]);
            if inputs is None {
                state["pairs"][f"{day}:{t['symbol']}"] = {"day": day, "ticker": t["symbol"], "action": "", "draft_action": "", "errors": ["not collected"], "votes": [], "research": [], "late_evidence": []};
            } else {
                running[t["symbol"]] = {d: NETWORK.submit(research, b) for (d, b) in briefs_for(day, inputs).items()};
            }
        }
        reports = {s: {d: f.result() for (d, f) in found.items()} for (s, found) in running.items()};
        decided = analyze(day, reports, macro.body if macro.complete() else None, {}, collection.sessions, rule) if reports else [];
        spent = limiter_now().sent - before;
        seconds = time.monotonic() - clock;
        for found in decided {
            inputs = collection.inputs_for(found.ticker);
            errors = inputs.fetch_errors if inputs is not None else [];
            row = decision_row(day, found, reports[found.ticker], macro_late, errors, round(spent / len(decided), 1), round(seconds, 1));
            state["pairs"][f"{day}:{found.ticker}"] = row;
            say(f"{day} {found.ticker}: {row['action']} (draft {row['draft_action']}, C {row['score']})");
        }
        state["requests"] += spent;
        state["seconds"] += seconds;
        save_state(state);
        say(f"{day}: {len(decided)} decisions, {spent} requests, {seconds:.0f}s");
    }
}

# --- scoring -------------------------------------------------------------------------------

"""Wilson's 95% interval for `hits` out of `n`."""
def wilson(hits: int, n: int) -> list[float] | None {
    if n == 0 {
        return None;
    }
    z = 1.959964;
    p = hits / n;
    middle = (p + z * z / (2 * n)) / (1 + z * z / n);
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n);
    return [round(middle - half, 4), round(middle + half, 4)];
}

def score(state: dict[str, any]) -> dict[str, any] {
    (days, sessions) = replay_sessions();
    rows = [state["pairs"][k] for k in sorted(state["pairs"])];
    symbols = sorted({r["ticker"] for r in rows} | {BENCHMARK});
    final = [s for s in sessions if bars_final(s)];
    (series, _gaps) = daily_bars(symbols, (date.fromisoformat(days[0]) - timedelta(days=10)).isoformat(), final[-1], run_budget());
    closes = {s.symbol: {b.day: b.close for b in s.bars} for s in series};
    for r in rows {
        window = vote_window(sessions, r["day"], HORIZON);
        r["excess_return"] = excess_return(closes, r["ticker"], window[0], window[1]) if window is not None and window[1] <= final[-1] else None;
        for v in r["votes"] {
            v["excess_return"] = r["excess_return"];
            direction = sign(STANCE_SCORE_BY_NAME.get(v["stance"] or "HOLD", 0));
            v["hit"] = (sign(r["excess_return"]) == direction) if direction != 0 and r["excess_return"] is not None else None;
        }
    }
    votes = [v for r in rows for v in r["votes"]];
    valid = [v for v in votes if v["valid"]];
    directional = [v for v in valid if v["hit"] is not None];
    hits = len([v for v in directional if v["hit"]]);
    buys = [r for r in rows if r["action"] in ("BUY", "ADD")];
    buy_excess = [r["excess_return"] for r in buys if r["excess_return"] is not None];
    stances: dict[str, int] = {};
    for v in valid {
        stances[v["stance"]] = stances.get(v["stance"], 0) + 1;
    }
    confidences = [v["confidence"] for v in valid];
    models: dict[str, int] = {};
    for r in rows {
        for v in r["votes"] {
            models[v["model"] or "none"] = models.get(v["model"] or "none", 0) + 1;
        }
        for x in r.get("research", []) {
            models[x["model"] or "none"] = models.get(x["model"] or "none", 0) + 1;
        }
    }
    complete = [r for r in rows if r["action"] and not r.get("forced_hold_reason") and r.get("score") is not None];
    notes = [
        f"stances of valid votes: {json.dumps(stances, sort_keys=True)}",
        f"confidence of valid votes: {min(confidences):.2f} to {max(confidences):.2f}" if confidences else "no valid votes",
        f"answers by model: {json.dumps(models, sort_keys=True)}",
        f"actions: {json.dumps({a: len([r for r in rows if r['action'] == a]) for a in sorted({r['action'] for r in rows})}, sort_keys=True)}",
        f"pairs held without a panel: {len([r for r in rows if r.get('forced_hold_reason')])}",
        f"pairs with any error: {len([r for r in rows if r['errors']])}"
    ];
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "model": PRIMARY_MODEL,
        "model_cutoff": MODEL_CUTOFF,
        "cutoff_source": CUTOFF_SOURCE,
        "days": days,
        "tickers": [t["symbol"] for t in state["tickers"]],
        "samples": 1,
        "requests_used": state["requests"],
        "wall_minutes": round(state["seconds"] / 60.0, 1),
        "audit": AUDIT,
        "decisions": rows,
        "summary": {
            "pairs": len(rows),
            "planned_pairs": len(days) * len(state["tickers"]),
            "complete": len(complete),
            "valid_votes": len(valid),
            "votes": len(votes),
            "directional_votes": len(directional),
            "hit_rate": round(hits / len(directional), 4) if directional else None,
            "hit_rate_ci": wilson(hits, len(directional)),
            "buys": len(buys),
            "buy_mean_excess": round(sum(buy_excess) / len(buy_excess), 5) if buy_excess else None,
            "late_evidence_count": sum(len(r["late_evidence"]) for r in rows),
            "screen_gaps": state.get("screen_gaps", [])[:20],
            "discarded": state.get("discarded", {}),
            "notes": notes
        }
    };
}

glob STANCE_SCORE_BY_NAME: dict[str, int] = {s.value: n for (s, n) in STANCE_SCORE.items()};

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        state = load_state();
        if os.environ.get("REPLAY_MODE", "run") == "run" {
            replay(state);
        }
        if state["pairs"] {
            OUT.parent.mkdir(parents=True, exist_ok=True);
            result = score(state);
            OUT.write_text(json.dumps(result, indent=1) + "\n");
            s = result["summary"];
            say(f"wrote {OUT}: {s['pairs']} of {s['planned_pairs']} pairs, {s['complete']} complete, {s['valid_votes']}/{s['votes']} valid votes, hit rate {s['hit_rate']} {s['hit_rate_ci']}, {result['requests_used']} requests");
        }
    }
}

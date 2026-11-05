"""Decision backtest (docs/spikes/2026-11-04-decision-backtest.md): how the live runs would
have traded under the current decision rule and specialist prompt.

It reads an export of the live runs (tests/spikes/export_runs.py), never the graph, so it
can run beside the live server. Three scenarios, each traded through the real sizing
(action/sizing.jac) and risk gate (action/gate.jac):
- `live`: the decisions the runs made.
- `replay`: the runs' stored votes through the current consensus rule. No model requests,
  and no Arbiter, so a buy here is the draft the Arbiter would have reviewed.
- `rerun`: the specialist panel and the Arbiter run again on the runs' stored research and
  macro brief with the current prompts (`run/analysis.jac`, `analyze`). This spends
  free-model requests, about 17 to 30 per ticker.

Every buy fills at the price at 9:45 a.m. New York on the run date, when the trading tick
executes, takes the gate's protective stop (2 x ATR), exits at the stop if a 5-minute bar
trades through it, and is otherwise marked at the latest close. SPY over the same window is
the benchmark. Before each batch of re-run tickers it reads OpenRouter's free-request count
and stops while BACKTEST_KEEP requests are still left for the next morning run.

    set -a && source .env && set +a
    TRADING_AGENT_RUN_SPIKE=1 BACKTEST_RUNS=runs.json BACKTEST_RERUN=2026-11-04 \
        BACKTEST_OUT=backtest.json jac run --no-takeover tests/spikes/decision_backtest.jac
"""
import json;
import math;
import os;
import sys;
import from datetime { date, datetime, timedelta, timezone }
import from pathlib { Path }
import httpx;
import from action.gate { Book, BookPosition, Instrument, Proposal, check_orders }
import from action.sizing { SizingCandidate, size_positions }
import from agents.models { LIMITER }
import from agents.research { ResearchResult }
import from analysis.consensus { ConsensusConfig, consensus, decide, draft_action, enough_samples }
import from models.agents { Domain, Evidence, MacroReport, ResearchReport, RiskRegime, Specialist, Stance, Vote }
import from models.graph { OrderSide, TradeAction }
import from models.research { RegimeInputs }
import from research.alpaca { alpaca_headers }
import from run.analysis { Holding, TickerAnalysis, analyze }

glob RUN_ENV: str = "TRADING_AGENT_RUN_SPIKE";
glob BARS_URL: str = "https://data.alpaca.markets/v2/stocks/bars";
glob KEY_URL: str = "https://openrouter.ai/api/v1/key";
# The rule before November 4, 2026, and the current one.
glob BEFORE: ConsensusConfig = ConsensusConfig(buy_score=0.35, buy_agreement=0.6);
glob CURRENT: ConsensusConfig = ConsensusConfig();
glob EQUITY: float = 100000.0;
# 9:45 a.m. New York in UTC in November (EST), when the trading tick executes a run.
glob EXECUTE_UTC: str = "14:45:00";
# Requests one ticker's panel, two extra samples, parse retries, and Arbiter can take.
glob PER_TICKER_CEILING: int = 30;
glob BATCH: int = 3;
glob GRID_SCORES: list[float] = [0.35, 0.3, 0.25, 0.2, 0.15, 0.1];
glob GRID_AGREEMENT: list[float] = [0.6, 0.5, 0.4];
glob BUYS: tuple[TradeAction, ...] = (TradeAction.BUY, TradeAction.ADD);
glob HOLIDAYS: set[str] = {"2026-11-26", "2026-12-25", "2027-01-01"};

# --- the export, read into typed records ---------------------------------------------------

def text(d: dict[str, object], key: str) -> str {
    v = d.get(key);
    return v if isinstance(v, str) else "";
}

def number(d: dict[str, object], key: str) -> float | None {
    v = d.get(key);
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None;
}

def whole(d: dict[str, object], key: str) -> int | None {
    v = d.get(key);
    return v if isinstance(v, int) and not isinstance(v, bool) else None;
}

def record(d: dict[str, object], key: str) -> dict[str, object] {
    v = d.get(key);
    return {str(k): x for (k, x) in v.items()} if isinstance(v, dict) else {};
}

def records(d: dict[str, object], key: str) -> list[dict[str, object]] {
    v = d.get(key);
    return [{str(k): x for (k, x) in item.items()} for item in v if isinstance(item, dict)] if isinstance(v, list) else [];
}

def texts(d: dict[str, object], key: str) -> list[str] {
    v = d.get(key);
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else [];
}

def wholes(d: dict[str, object], key: str) -> list[int] {
    v = d.get(key);
    return [x for x in v if isinstance(x, int) and not isinstance(x, bool)] if isinstance(v, list) else [];
}

"""The market figures a run stored for one covered ticker (models/graph.jac, Coverage)."""
obj Figures {
    has sector: str = "",
        atr_14: float | None = None,
        volume_20: float | None = None,
        realized_vol_20: float | None = None,
        sessions_to_earnings: int | None = None,
        dropped_samples: int = 0;
}

obj StoredVote {
    has specialist: Specialist,
        sample: int,
        vote: Vote;
}

obj StoredResearch {
    has domain: Domain,
        followup: str,
        model: str,
        body: ResearchReport;
}

"""One covered ticker in one run: its inputs and what the run decided."""
obj StoredTicker {
    has ticker: str,
        figures: Figures,
        research: list[StoredResearch],
        votes: list[StoredVote],
        action: TradeAction,
        conviction: float;
    has forced_hold: str = "",
        score: float | None = None,
        agreement: float | None = None,
        ci_low: float | None = None;
}

obj StoredRun {
    has day: str,
        tickers: dict[str, StoredTicker];
    has macro: MacroReport | None = None,
        regime: RegimeInputs | None = None;
}

def evidence_of(items: list[dict[str, object]]) -> list[Evidence] {
    return [Evidence(claim=text(e, "claim"), source_url=text(e, "source_url"), published=text(e, "published")) for e in items];
}

def report_of(b: dict[str, object]) -> ResearchReport {
    return ResearchReport(summary=text(b, "summary"), view=Stance(text(b, "view")), confidence=number(b, "confidence") or 0.0, evidence=evidence_of(records(b, "evidence")), risks=texts(b, "risks"), data_gaps=texts(b, "data_gaps"));
}

def macro_of(m: dict[str, object]) -> MacroReport | None {
    b = record(m, "body");
    if not b {
        return None;
    }
    return MacroReport(summary=text(b, "summary"), regime=RiskRegime(text(b, "regime")), confidence=number(b, "confidence") or 0.0, evidence=evidence_of(records(b, "evidence")), risks=texts(b, "risks"), data_gaps=texts(b, "data_gaps"));
}

def regime_of(m: dict[str, object]) -> RegimeInputs | None {
    i = record(m, "inputs");
    if not i {
        return None;
    }
    return RegimeInputs(spy_close=number(i, "spy_close"), spy_sma_200=number(i, "spy_sma_200"), spy_vol_20=number(i, "spy_vol_20"), spy_as_of=text(i, "spy_as_of"));
}

def vote_of(r: dict[str, object]) -> StoredVote {
    b = record(r, "body");
    return StoredVote(
        specialist=Specialist(text(r, "specialist")),
        sample=whole(r, "sample") or 0,
        vote=Vote(stance=Stance(text(b, "stance")), confidence=number(b, "confidence") or 0.0, horizon_days=whole(b, "horizon_days") or 1, rationale=text(b, "rationale"), cited_evidence=wholes(b, "cited_evidence"), cited_gaps=texts(b, "cited_gaps"))
    );
}

def ticker_of(t: dict[str, object]) -> StoredTicker {
    cov = record(t, "coverage");
    decision = record(t, "decision");
    found = record(t, "consensus");
    return StoredTicker(
        ticker=text(cov, "ticker"),
        figures=Figures(sector=text(cov, "sector"), atr_14=number(cov, "atr_14"), volume_20=number(cov, "volume_20"), realized_vol_20=number(cov, "realized_vol_20"), sessions_to_earnings=whole(cov, "sessions_to_earnings"), dropped_samples=len(texts(cov, "analysis_errors"))),
        research=[StoredResearch(domain=Domain(text(r, "domain")), followup=text(r, "followup_question"), model=text(r, "model"), body=report_of(record(r, "body"))) for r in records(t, "research")],
        votes=[vote_of(v) for v in records(t, "votes")],
        action=TradeAction(text(decision, "action") or "HOLD"),
        conviction=number(decision, "conviction") or 0.0,
        forced_hold=text(decision, "forced_hold_reason"),
        score=number(found, "score"),
        agreement=number(found, "agreement"),
        ci_low=number(found, "ci_low")
    );
}

def load_runs(path: Path) -> dict[str, StoredRun] {
    raw = json.loads(path.read_text());
    found: dict[str, StoredRun] = {};
    for (day, run) in raw.items() {
        r = {str(k): v for (k, v) in run.items()};
        m = record(r, "macro");
        tickers = [ticker_of(t) for t in record(r, "tickers").values() if isinstance(t, dict)];
        found[str(day)] = StoredRun(day=str(day), tickers={t.ticker: t for t in tickers}, macro=macro_of(m), regime=regime_of(m));
    }
    return found;
}

# --- rebuilding what the panel read --------------------------------------------------------

"""The reports a ticker's panel read: per domain, the newest follow-up that found evidence,
else the first report (run/guard.jac, `_keep`)."""
def research_of(t: StoredTicker) -> dict[Domain, ResearchResult] {
    found: dict[Domain, ResearchResult] = {};
    for r in t.research {
        if r.domain not in found or (r.followup and r.body.evidence) {
            found[r.domain] = ResearchResult(ticker=t.ticker, domain=r.domain, body=r.body, model=r.model, cited=len(r.body.evidence));
        }
    }
    return found;
}

def votes_of(t: StoredTicker) -> dict[Specialist, list[Vote]] {
    found: dict[Specialist, list[Vote]] = {};
    for v in sorted(t.votes, key=lambda (v: StoredVote) -> tuple[str, int] { (v.specialist.value, v.sample); }) {
        found.setdefault(v.specialist, []).append(v.vote);
    }
    return found;
}

"""Weekday sessions around `day`, without the market holidays in range."""
def sessions_around(day: str) -> list[str] {
    start = date.fromisoformat(day) - timedelta(days=7);
    found: list[str] = [];
    for n in range(120) {
        d = start + timedelta(days=n);
        if d.weekday() < 5 and d.isoformat() not in HOLIDAYS {
            found.append(d.isoformat());
        }
    }
    return found;
}

# --- the three scenarios -------------------------------------------------------------------

"""One ticker's decision in one scenario."""
obj Pick {
    has day: str,
        ticker: str,
        action: TradeAction,
        conviction: float;
    has score: float | None = None,
        agreement: float | None = None,
        ci_low: float | None = None,
        note: str = "";
}

def live_picks(run: StoredRun) -> list[Pick] {
    return [Pick(day=run.day, ticker=t.ticker, action=t.action, conviction=t.conviction, score=t.score, agreement=t.agreement, ci_low=t.ci_low) for t in sorted(run.tickers.values(), key=lambda (t: StoredTicker) -> str { t.ticker; })];
}

"""The stored votes through `config`'s rule, as the draft the Arbiter would review. A ticker
the run held without a panel (missing research, a flag, too few samples) still holds."""
def replay_picks(run: StoredRun, held: set[str], config: ConsensusConfig) -> list[Pick] {
    found: list[Pick] = [];
    for t in sorted(run.tickers.values(), key=lambda (t: StoredTicker) -> str { t.ticker; }) {
        votes = votes_of(t);
        valid = sum(len(vs) for vs in votes.values());
        c = consensus(votes, f"{t.ticker}:{run.day}", config);
        if t.forced_hold or c is None or not enough_samples(valid, valid + t.figures.dropped_samples, config) {
            found.append(Pick(day=run.day, ticker=t.ticker, action=TradeAction.HOLD if t.ticker in held else TradeAction.NO_ACTION, conviction=0.0, note="held without a panel"));
            continue;
        }
        found.append(Pick(day=run.day, ticker=t.ticker, action=draft_action(c, t.ticker in held, False, config), conviction=c.conviction(), score=c.score, agreement=c.agreement, ci_low=c.ci_low));
    }
    return found;
}

"""Free-model requests OpenRouter says are left today, or None when it does not say."""
def free_requests_left -> int | None {
    response = httpx.get(KEY_URL, headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}"}, timeout=30);
    body = response.json();
    data = body.get("data") if isinstance(body, dict) else None;
    counts = data.get("free_model_daily_requests") if isinstance(data, dict) else None;
    left = counts.get("remaining") if isinstance(counts, dict) else None;
    return int(left) if isinstance(left, (int, float)) else None;
}

"""Run the panel and the Arbiter again on the run's stored research, in batches, while the
day's free requests stay above `keep`. Returns the picks, the analyses, and the tickers it
left out."""
def rerun_picks(run: StoredRun, held: set[str], keep: int) -> tuple[list[Pick], list[TickerAnalysis], list[str]] {
    sessions = sessions_around(run.day);
    tickers = sorted(run.tickers);
    picks: list[Pick] = [];
    analyses: list[TickerAnalysis] = [];
    skipped: list[str] = [];
    for start in range(0, len(tickers), BATCH) {
        batch = tickers[start:start + BATCH];
        left = free_requests_left();
        if left is not None and left - PER_TICKER_CEILING * len(batch) < keep {
            skipped.extend(tickers[start:]);
            break;
        }
        research = {t: research_of(run.tickers[t]) for t in batch};
        holdings = {t: Holding(ticker=t) for t in batch if t in held};
        before = LIMITER.sent;
        for a in analyze(run.day, research, run.macro, holdings, sessions, CURRENT) {
            c = a.consensus;
            analyses.append(a);
            picks.append(Pick(day=run.day, ticker=a.ticker, action=a.action(), conviction=a.conviction(), score=c.score if c is not None else None, agreement=c.agreement if c is not None else None, ci_low=c.ci_low if c is not None else None, note=a.forced_hold_reason));
        }
        say(f"  {run.day} {', '.join(batch)}: {LIMITER.sent - before} requests, {LIMITER.sent} in all");
    }
    return (picks, analyses, skipped);
}

# --- prices --------------------------------------------------------------------------------

obj Bar {
    has t: str,
        o: float,
        l: float,
        c: float;
}

"""5-minute bars by symbol from `start` (UTC ISO) to twenty minutes ago, oldest first."""
def bars(symbols: list[str], start: str) -> dict[str, list[Bar]] {
    found: dict[str, list[Bar]] = {s: [] for s in symbols};
    end = (datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ");
    token = "";
    while True {
        params = {"symbols": ",".join(symbols), "timeframe": "5Min", "start": start, "end": end, "feed": "sip", "adjustment": "all", "limit": "10000"};
        if token {
            params["page_token"] = token;
        }
        response = httpx.get(BARS_URL, params=params, headers=alpaca_headers(), timeout=60);
        response.raise_for_status();
        body = {str(k): v for (k, v) in response.json().items()};
        for (s, rows) in record(body, "bars").items() {
            if isinstance(rows, list) {
                for row in rows {
                    if isinstance(row, dict) {
                        b = {str(k): v for (k, v) in row.items()};
                        found.setdefault(s, []).append(Bar(t=text(b, "t"), o=number(b, "o") or 0.0, l=number(b, "l") or 0.0, c=number(b, "c") or 0.0));
                    }
                }
            }
        }
        token = text(body, "next_page_token");
        if not token {
            return found;
        }
    }
    return found;
}

"""The price each symbol traded at when the trading tick ran on `day`: the open of the first
5-minute bar at or after 9:45 a.m. New York."""
def execution_prices(series: dict[str, list[Bar]], day: str) -> dict[str, float] {
    at = f"{day}T{EXECUTE_UTC}Z";
    found: dict[str, float] = {};
    for (s, rows) in series.items() {
        for b in rows {
            if b.t >= at {
                found[s] = b.o;
                break;
            }
        }
    }
    return found;
}

# --- trading a scenario --------------------------------------------------------------------

"""An open or closed position in a scenario's simulated book. `how` is open, stopped (a bar
traded through the stop), or sold (the rule sold it at a later 9:45 tick)."""
obj Lot {
    has ticker: str,
        day: str,
        qty: int,
        price_in: float,
        stop: float;
    has price_out: float | None = None,
        out_at: str = "",
        how: str = "open",
        mark: float = 0.0,
        spy_return: float = 0.0,
        credited: bool = False;

    def value_now -> float {
        return self.price_out if self.price_out is not None else self.mark;
    }

    def pnl -> float {
        return self.qty * (self.value_now() - self.price_in);
    }

    def ret -> float {
        return self.value_now() / self.price_in - 1.0;
    }
}

"""Close `lot` at its stop if a bar after its entry traded through it, else mark it at the
latest close; and take SPY's return over the time it was held. A stop fills at the stop, or at
the bar's open when the bar gapped below it."""
def settle(lot: Lot, rows: list[Bar], spy: list[Bar]) {
    at = f"{lot.day}T{EXECUTE_UTC}Z";
    after = [b for b in rows if b.t >= at];
    end_at = lot.out_at or (after[-1].t if after else at);
    if lot.price_out is None {
        for b in after {
            if b.l <= lot.stop {
                (lot.price_out, lot.out_at, lot.how, end_at) = (min(lot.stop, b.o), b.t, "stopped", b.t);
                break;
            }
        }
    }
    lot.mark = after[-1].c if after else lot.price_in;
    window = [b for b in spy if at <= b.t <= end_at];
    if window {
        lot.spy_return = window[-1].c / window[0].o - 1.0;
    }
}

"""Trade one scenario's picks day by day through the real sizing and gate, starting from
cash, and settle every position against `series`."""
def trade(picks: list[Pick], runs: dict[str, StoredRun], series: dict[str, list[Bar]]) -> tuple[list[Lot], list[str]] {
    lots: list[Lot] = [];
    notes: list[str] = [];
    cash = EQUITY;
    peak = EQUITY;
    for day in sorted({p.day for p in picks}) {
        at = f"{day}T{EXECUTE_UTC}Z";
        # Stops that triggered since the last tick return their proceeds to cash.
        for lot in lots {
            if lot.price_out is None {
                settle(lot, [b for b in series.get(lot.ticker, []) if b.t < at], series.get("SPY", []));
            }
            if lot.price_out is not None and not lot.credited {
                cash += lot.qty * lot.price_out;
                lot.credited = True;
            }
        }
        prices = execution_prices(series, day);
        run = runs[day];
        held: dict[str, int] = {};
        for lot in lots {
            if lot.price_out is None {
                held[lot.ticker] = held.get(lot.ticker, 0) + lot.qty;
            }
        }
        equity = cash + sum(q * prices.get(t, 0.0) for (t, q) in held.items());
        peak = max(peak, equity);
        candidates: list[SizingCandidate] = [];
        for p in [p for p in picks if p.day == day and p.ticker in prices] {
            candidates.append(SizingCandidate(ticker=p.ticker, action=p.action, conviction=min(1.0, max(0.0, p.conviction)), price=prices[p.ticker], realized_vol_20=run.tickers[p.ticker].figures.realized_vol_20, current_qty=held.get(p.ticker, 0)));
        }
        named = {c.ticker for c in candidates};
        for (t, q) in held.items() {
            if t not in named and t in prices {
                candidates.append(SizingCandidate(ticker=t, action=TradeAction.HOLD, conviction=0.0, price=prices[t], current_qty=q));
            }
        }
        plan = size_positions(candidates, equity);
        by_ticker = {c.ticker: c for c in candidates};
        proposals = [Proposal(ticker=s.ticker, action=by_ticker[s.ticker].action, side=s.side, qty=abs(s.share_delta), conviction=by_ticker[s.ticker].conviction) for s in plan.positions if s.side is not None and s.share_delta != 0];
        instruments: dict[str, Instrument] = {};
        for c in candidates {
            f = run.tickers[c.ticker].figures if c.ticker in run.tickers else Figures();
            instruments[c.ticker] = Instrument(ticker=c.ticker, price=c.price, sector=f.sector, trade_age_minutes=0.0, atr_14=f.atr_14, volume_20=f.volume_20, sessions_to_earnings=f.sessions_to_earnings);
        }
        book = Book(equity=equity, peak_equity=peak, positions={t: BookPosition(ticker=t, qty=q, price=prices.get(t, 0.0), sector=instruments[t].sector if t in instruments else "") for (t, q) in held.items()});
        for r in check_orders(proposals, book, instruments, run.regime) {
            price = prices[r.ticker];
            if r.approved_qty <= 0 {
                notes.append(f"{day} {r.ticker} {r.side.value} {r.requested_qty}: refused by {r.rejected_by()}");
            } elif r.side == OrderSide.BUY {
                lots.append(Lot(ticker=r.ticker, day=day, qty=r.approved_qty, price_in=price, stop=price - r.stop_distance));
                cash -= r.approved_qty * price;
                notes.append(f"{day} {r.ticker} buy {r.approved_qty} at {price:.2f}, stop {price - r.stop_distance:.2f}");
            } else {
                left = r.approved_qty;
                for lot in list(lots) {
                    if lot.ticker == r.ticker and lot.price_out is None and left > 0 {
                        if lot.qty > left {
                            lot.qty -= left;
                            lots.append(Lot(ticker=lot.ticker, day=lot.day, qty=left, price_in=lot.price_in, stop=lot.stop, price_out=price, out_at=at, how="sold", credited=True));
                            left = 0;
                        } else {
                            (lot.price_out, lot.out_at, lot.how, lot.credited) = (price, at, "sold", True);
                            left -= lot.qty;
                        }
                    }
                }
                cash += r.approved_qty * price;
                notes.append(f"{day} {r.ticker} sell {r.approved_qty} at {price:.2f}");
            }
        }
    }
    for lot in lots {
        settle(lot, series.get(lot.ticker, []), series.get("SPY", []));
    }
    return (lots, notes);
}

"""Write one line of the backtest's report to stdout."""
def say(line: str) {
    sys.stdout.write(line + "\n");
    sys.stdout.flush();
}

def summary(name: str, picks: list[Pick], lots: list[Lot], notes: list[str]) -> dict[str, object] {
    pnl = sum(l.pnl() for l in lots);
    spy_pnl = sum(l.qty * l.price_in * l.spy_return for l in lots);
    say(f"\n== {name}: {len([p for p in picks if p.action in BUYS])} buys decided, {len(lots)} filled");
    for n in notes {
        say("   " + n);
    }
    for l in lots {
        say("   " + l.day + " " + l.ticker.ljust(5) + " " + str(l.qty).rjust(4) + " x " + format(l.price_in, "8.2f") + " -> " + format(l.value_now(), "8.2f") + " (" + l.how + "): " + format(l.ret(), "+.2%") + ", SPY " + format(l.spy_return, "+.2%") + ", P&L " + format(l.pnl(), "+,.2f"));
    }
    say("   P&L " + format(pnl, "+,.2f") + " on " + format(EQUITY, ",.0f") + " (" + format(pnl / EQUITY, "+.3%") + "); the same dollars in SPY " + format(spy_pnl, "+,.2f"));
    return {
        "scenario": name,
        "buys": [{"day": p.day, "ticker": p.ticker, "action": p.action.value, "conviction": p.conviction, "score": p.score, "agreement": p.agreement, "ci_low": p.ci_low} for p in picks if p.action in BUYS],
        "lots": [{"day": l.day, "ticker": l.ticker, "qty": l.qty, "price_in": l.price_in, "stop": l.stop, "price_out": l.price_out, "out_at": l.out_at, "how": l.how, "mark": l.mark, "return": l.ret(), "spy_return": l.spy_return, "pnl": l.pnl()} for l in lots],
        "notes": notes,
        "pnl": pnl,
        "spy_pnl": spy_pnl
    };
}

"""How many of `picks` would buy at each threshold pair, with their mean return less SPY's
since 9:45 on the run date, to show the rule's sensitivity (not to tune it on)."""
def grid(picks: list[Pick], series: dict[str, list[Bar]]) -> list[dict[str, object]] {
    found: list[dict[str, object]] = [];
    say("\n== threshold grid on the re-run consensus: buys (mean return less SPY's since 9:45)");
    for a in GRID_AGREEMENT {
        cells: list[str] = [];
        for s in GRID_SCORES {
            config = ConsensusConfig(buy_score=s, buy_agreement=a);
            chosen: list[Pick] = [];
            for p in picks {
                if p.score is not None and p.agreement is not None and p.ci_low is not None and decide(p.score, p.agreement, p.ci_low, False, False, config) == TradeAction.BUY {
                    chosen.append(p);
                }
            }
            excess: list[float] = [];
            for p in chosen {
                price = execution_prices({p.ticker: series.get(p.ticker, [])}, p.day).get(p.ticker);
                if price is not None {
                    lot = Lot(ticker=p.ticker, day=p.day, qty=1, price_in=price, stop=0.0);
                    settle(lot, series.get(p.ticker, []), series.get("SPY", []));
                    excess.append(lot.ret() - lot.spy_return);
                }
            }
            mean = sum(excess) / len(excess) if excess else None;
            cells.append("C>=" + format(s, ".2f") + ": " + str(len(chosen)).rjust(2) + ((" (" + format(mean, "+.2%") + ")") if mean is not None else "         "));
            found.append({"buy_score": s, "buy_agreement": a, "buys": [p.ticker + "@" + p.day for p in chosen], "mean_excess": mean});
        }
        say("   A>=" + format(a, ".1f") + "  " + "  ".join(cells));
    }
    return found;
}

"""Stance counts by specialist."""
def stance_counts(votes: list[tuple[str, Stance]]) -> dict[str, dict[str, int]] {
    found: dict[str, dict[str, int]] = {};
    for (specialist, stance) in votes {
        counts = found.setdefault(specialist, {});
        counts[stance.value] = counts.get(stance.value, 0) + 1;
    }
    return found;
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        runs = load_runs(Path(os.environ.get("BACKTEST_RUNS", "runs.json")));
        rerun_days = [d for d in os.environ.get("BACKTEST_RERUN", "").split(",") if d];
        keep = int(os.environ.get("BACKTEST_KEEP", "620"));
        days = sorted(runs);
        symbols = sorted({t for r in runs.values() for t in r.tickers} | {"SPY"});
        series = bars(symbols, f"{days[0]}T14:30:00Z");
        outcome: dict[str, object] = {"days": days, "rerun_days": rerun_days, "started": datetime.now(timezone.utc).isoformat(), "free_requests_left_before": free_requests_left() if rerun_days else None};

        live = [p for d in days for p in live_picks(runs[d])];
        (live_lots, live_notes) = trade(live, runs, series);
        scenarios = [summary("live: the decisions the runs made", live, live_lots, live_notes)];

        replayed: list[Pick] = [];
        for d in days {
            held = {l.ticker for l in trade(replayed, runs, series)[0] if l.price_out is None or l.out_at > f"{d}T{EXECUTE_UTC}Z"} if replayed else set();
            replayed.extend(replay_picks(runs[d], held, CURRENT));
        }
        (replay_lots, replay_notes) = trade(replayed, runs, series);
        scenarios.append(summary("replay: stored votes, current rule, no Arbiter", replayed, replay_lots, replay_notes));

        if rerun_days {
            say("\nRe-running the panel and the Arbiter:");
            rerun: list[Pick] = [];
            analyses: list[TickerAnalysis] = [];
            skipped: list[str] = [];
            for d in rerun_days {
                (found, done, missed) = rerun_picks(runs[d], set(), keep);
                rerun.extend(found);
                analyses.extend(done);
                skipped.extend(f"{t}@{d}" for t in missed);
            }
            if skipped {
                say(f"  not re-run, to keep {keep} requests for the next run: {', '.join(skipped)}");
            }
            (rerun_lots, rerun_notes) = trade(rerun, runs, series);
            scenarios.append(summary("rerun: current prompt and rule, with the Arbiter", rerun, rerun_lots, rerun_notes));
            stored = stance_counts([(v.specialist.value, v.vote.stance) for d in rerun_days for t in runs[d].tickers.values() for v in t.votes]);
            again = stance_counts([(r.specialist.value, r.vote.stance) for a in analyses for r in a.votes if r.vote is not None]);
            say("\n== stances, stored run -> re-run");
            for s in sorted(stored) {
                say("   " + s.ljust(13) + " " + json.dumps(stored[s], sort_keys=True) + "  ->  " + json.dumps(again.get(s, {}), sort_keys=True));
            }
            outcome["stances"] = {"stored": stored, "rerun": again};
            outcome["rerun"] = [{"day": p.day, "ticker": p.ticker, "action": p.action.value, "score": p.score, "agreement": p.agreement, "ci_low": p.ci_low, "conviction": p.conviction, "note": p.note} for p in rerun];
            outcome["rerun_skipped"] = skipped;
            outcome["arbiter"] = [{"ticker": a.ticker, "draft": a.draft.value, "action": a.action().value, "verdict": str(a.ruling.verdict) if a.ruling is not None else "", "reason": a.ruling.downgrade_reason if a.ruling is not None else ""} for a in analyses if a.draft in BUYS];
            outcome["grid"] = grid(rerun, series);
            outcome["requests"] = LIMITER.sent;
            outcome["free_requests_left_after"] = free_requests_left();
        }
        outcome["scenarios"] = scenarios;
        Path(os.environ.get("BACKTEST_OUT", "backtest.json")).write_text(json.dumps(outcome, indent=1));
    }
}

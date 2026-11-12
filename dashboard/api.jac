"""The dashboard's endpoints (TDD §10): read-only views of the signed-in user's own agent. None
is public, and none takes an argument that names an agent: `my_portfolio` finds the caller's.

Each endpoint finds the portfolio without creating it, walks the stored graph, and returns a
view from models/views.jac. Nothing here writes, calls a model, or reaches Alpaca,
so a page loads from what the pipeline already stored and cannot spend the request budget
(TDD §10, design notes). The builders take the portfolio as an argument, so tests can run
them on any graph; the endpoints only pick the caller's.

Views come through the read cache in dashboard/cache.jac, and refresh_job rebuilds the
portfolio, performance, and run list every minute, so a page shows the graph as of at most
a minute or two ago.
"""
import math;
import re;
import statistics;
import from datetime { datetime, timezone }
import from urllib.parse { urlsplit }
import from accounts.store { AGENT_PORTFOLIO, my_portfolio }
import from action.baselines { baselines_of, sim_marks }
import from action.insights { DISCLAIMER }
import from action.reconcile { marks_of }
import from agents.specialists { NO_EVIDENCE, packet }
import from dashboard.cache { VIEWS }
import from analysis.consensus { abstains, signed_score }
import from analysis.evaluation { latest_evaluation }
import from analysis.scoring { hit, tally_votes }
import from models.agents { Domain, Evidence, ResearchReport, Specialist }
import from models.evaluation { Evaluation }
import from models.graph {
    BaselineKind,
    CheckedBy,
    Concluded,
    ConsensusResult,
    Coverage,
    Covers,
    DailyMark,
    Decided,
    Decision,
    Fill,
    FilledBy,
    HasMacro,
    Holds,
    MacroRecord,
    OpenedBy,
    Order,
    OrderSide,
    Placed,
    Portfolio,
    Position,
    Ran,
    Researched,
    ResearchRecord,
    RiskCheck,
    Run,
    Sent,
    StoppedBy,
    VoteRecord,
    Voted
}
import from models.views {
    ConsensusView,
    CoverageRow,
    DecisionView,
    EvidenceView,
    FillView,
    GateView,
    MacroView,
    MarkPoint,
    OrderView,
    PerformanceView,
    PortfolioView,
    PositionView,
    ResearchView,
    RuleView,
    RunSummary,
    RunView,
    SampleView,
    Series,
    SpecialistView,
    CalibrationBinView,
    SpecialistSummaryView,
    SpecialistVoteView,
    TrailView
}
import from dashboard.live { live_view }
import from run.guard { TEAM_PORTFOLIO }

glob TRADING_DAYS: int = 252;
glob RECENT_ORDERS: int = 60;
glob RECENT_CLOSED: int = 40;
glob MAX_RUNS: int = 250;
glob SPECIALIST_RUNS: int = 60;
glob RECENT_SPECIALIST_VOTES: int = 8;
glob SPECIALIST_ROLES: list[Specialist] = [Specialist.FUNDAMENTALS, Specialist.TECHNICAL, Specialist.NEWS, Specialist.MACRO, Specialist.FLOW];
glob SERIES_LABELS: dict[str, str] = {"team": "Your agent", "equal_weight": "Equal-weight shortlist", "spy": "SPY buy-and-hold"};
# How run/analysis.jac `record_analysis` words a dropped sample: "<role> sample <n>: <error>".
glob SAMPLE_ERROR: re.Pattern[str] = re.compile(r"^(\w+) sample (\d+): (.*)$", re.DOTALL);
# The heads of the executor's execution note (action/executor.jac `execute_run`).
glob EXECUTED: re.Pattern[str] = re.compile(r"^(\d+) checks?, (\d+) approved");
glob ORDERS_OFF: re.Pattern[str] = re.compile(r"orders are disabled [^;]*; (\d+) checks? recorded, nothing sent");
# Alpaca's order statuses in plain words; any other status is still working at the broker.
glob ORDER_WORDS: dict[str, str] = {
    "filled": "filled",
    "partially_filled": "partly filled",
    "canceled": "canceled",
    "expired": "expired",
    "replaced": "replaced",
    "done_for_day": "done for the day",
    "rejected": "broker rejected"
};
# Research is shown nearest the price first, as on the insight cards (action/insights.jac).
glob DOMAIN_ORDER: list[Domain] = [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS, Domain.MACRO];

"""The team portfolio on root.shared, or None before the first run creates it."""
def find_team -> Portfolio | None {
    for p in [root.shared -->[?:Portfolio]] {
        if p.name == TEAM_PORTFOLIO {
            return p;
        }
    }
    return None;
}

"""A cache key for one of a portfolio's views; the portfolio's id keeps agents apart."""
def view_key(team: Portfolio, *parts: str) -> str {
    return ":".join([jid(team)] + list(parts));
}

"""The caller's portfolio, with its positions and its most recently submitted orders: at its last
mark, overlaid with what Alpaca values the account at now when it can be asked (`live_at`,
dashboard/live.jac)."""
def:priv get_portfolio -> PortfolioView {
    team = my_portfolio();
    if team is None {
        return PortfolioView(name=AGENT_PORTFOLIO, mode="insight", started=False);
    }
    return live_view(view_key(team, "live"), VIEWS.get(view_key(team, "portfolio"), portfolio_view, team), team);
}

"""The team portfolio's daily equity beside both forward-test baselines."""
def:priv get_performance -> PerformanceView {
    team = my_portfolio();
    if team is None {
        return PerformanceView(started=False);
    }
    return VIEWS.get(view_key(team, "performance"), performance_view, team);
}

"""The team's runs, newest first."""
def:priv list_runs -> list[RunSummary] {
    team = my_portfolio();
    if team is None {
        return [];
    }
    return VIEWS.get(view_key(team, "runs"), run_summaries, team);
}

"""The run for `run_date`, or the newest run when it is empty; None when there is none."""
def:priv get_run(run_date: str = "") -> RunView | None {
    team = my_portfolio();
    if team is None {
        return None;
    }
    return VIEWS.get(view_key(team, "run", run_date), run_view, team, run_date);
}

"""The caller's newest run from the read cache, for other modules' endpoints (market/api.jac)
that link to its decisions without walking the graph themselves."""
def my_latest_run -> RunView | None {
    team = my_portfolio();
    if team is None {
        return None;
    }
    return VIEWS.get(view_key(team, "run", ""), run_view, team, "");
}

"""One ticker's trail in the run for `run_date`, or None when the run did not cover it."""
def:priv get_decision_trail(run_date: str, ticker: str) -> TrailView | None {
    team = my_portfolio();
    if team is None {
        return None;
    }
    symbol = ticker.strip().upper();
    return VIEWS.get(view_key(team, "trail", run_date, symbol), trail_view, team, run_date, symbol);
}

"""The caller's agent's latest evaluation (TDD §13, metrics), as the evening review stored it,
or None before its first evening review."""
def:priv get_evaluation -> Evaluation | None {
    portfolio = my_portfolio();
    return latest_evaluation(portfolio) if portfolio is not None else None;
}

"""The five roles' recent votes and outcomes from the caller's own agent."""
def:priv get_specialists -> list[SpecialistSummaryView] {
    team = my_portfolio();
    if team is None {
        return [SpecialistSummaryView(specialist=s.value) for s in SPECIALIST_ROLES];
    }
    return VIEWS.get(view_key(team, "specialists"), specialist_summaries, team);
}

"""Rebuild the views every page opens with, so no reader waits for them (dashboard/cache.jac).
A static job runs as the system user, which reaches root.shared."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def refresh_job {
    team = find_team();
    if team is not None {
        VIEWS.put(view_key(team, "portfolio"), portfolio_view(team));
        VIEWS.put(view_key(team, "performance"), performance_view(team));
        VIEWS.put(view_key(team, "runs"), run_summaries(team));
        VIEWS.put(view_key(team, "run", ""), run_view(team, ""));
        refresh_specialists(team);
    }
}

# The runs the specialists view was last built from, by view key (see `refresh_specialists`).
glob _SPECIALISTS_BUILT_FROM: dict[str, str] = {};

"""What the specialists view depends on: each recent run's date, status, and when its votes were
scored. Reading it touches only the run nodes."""
def specialists_signature(portfolio: Portfolio) -> str {
    runs = runs_by_day(portfolio);
    return "|".join(f"{d}:{runs[d].status.value}:{runs[d].votes_scored_at}" for d in sorted(runs, reverse=True)[:SPECIALIST_RUNS]);
}

"""Keep the specialists view fresh, rebuilding it only when a run finishes or its votes are
scored, so the job does not reread the newest votes every minute."""
def refresh_specialists(team: Portfolio) {
    key = view_key(team, "specialists");
    signature = specialists_signature(team);
    found = VIEWS.entries.get(key);
    if found is not None and _SPECIALISTS_BUILT_FROM.get(key) == signature {
        VIEWS.put(key, found.value);
        return;
    }
    VIEWS.put(key, specialist_summaries(team));
    _SPECIALISTS_BUILT_FROM[key] = signature;
}

# --- Portfolio --------------------------------------------------------------------------

def sorted_marks(found: dict[str, DailyMark]) -> list[DailyMark] {
    return [found[d] for d in sorted(found)];
}

def portfolio_view(portfolio: Portfolio) -> PortfolioView {
    marks = sorted_marks(marks_of(portfolio));
    view = PortfolioView(
        name=portfolio.name,
        mode=portfolio.mode.value,
        started=bool(marks),
        demo=portfolio.demo,
        opened_at=portfolio.opened_at,
        starting_cash=portfolio.starting_cash
    );
    held = [p for p in [portfolio ->:Holds:->[?:Position]]];
    sent = [o for o in [portfolio ->:Sent:->[?:Order]]];
    if marks {
        last = marks[-1];
        before = marks[-2].equity if len(marks) > 1 else portfolio.starting_cash;
        view.as_of = last.marked_at;
        view.last_day = last.day;
        view.equity = last.equity;
        view.cash = last.cash;
        view.positions_value = last.positions_value;
        view.day_pnl = last.equity - before;
        view.day_return = last.equity / before - 1.0 if before > 0 else None;
        view.total_pnl = last.equity - portfolio.starting_cash;
        view.total_return = last.equity / portfolio.starting_cash - 1.0 if portfolio.starting_cash > 0 else None;
        view.peak_equity = last.peak_equity;
        view.drawdown = last.drawdown;
        view.gross_exposure = last.positions_value / last.equity if last.equity > 0 else None;
        view.sessions = len(marks);
        view.bypasses = sum(len(m.bypasses) for m in marks);
        view.drift = sum(len(m.drift) for m in marks);
    }
    equity = view.equity;
    view.positions = sorted(
        [position_view(p, equity, sent) for p in held if p.open()],
        key=lambda (v: PositionView) { -(v.market_value or 0.0); }
    );
    closed = sorted([p for p in held if not p.open()], key=lambda (p: Position) { p.closed_at; }, reverse=True);
    view.closed = [position_view(p, equity, sent) for p in closed[:RECENT_CLOSED]];
    recent = sorted(sent, key=lambda (o: Order) { (o.submitted_at, o.client_order_id); }, reverse=True);
    view.orders = [order_view(o) for o in recent[:RECENT_ORDERS]];
    return view;
}

"""The decision that opened `position`, and the date of its run."""
def opening_decision(position: Position) -> tuple[Decision | None, str] {
    for d in [position ->:OpenedBy:->[?:Decision]] {
        return (d, decision_day(d));
    }
    return (None, "");
}

def decision_day(d: Decision) -> str {
    for cov in [d <-:Decided:<-[?:Coverage]] {
        for run in [cov <-:Covers:<-[?:Run]] {
            return run.run_date;
        }
    }
    return "";
}

"""A position as the dashboard shows it. An open one is valued at its last price; a closed
one's P&L is realized from the fills of the sells that closed it."""
def position_view(position: Position, equity: float | None, sent: list[Order]) -> PositionView {
    (d, day) = opening_decision(position);
    view = PositionView(
        ticker=position.ticker,
        sector=position.sector,
        qty=position.qty,
        avg_entry_price=position.avg_entry_price,
        opened_at=position.opened_at,
        stop_price=position.stop_price or None,
        time_stop=position.time_stop or (d.time_stop if d is not None else ""),
        thesis=d.thesis if d is not None else "",
        decision_day=day
    );
    if position.open() {
        price = position.last_price or None;
        view.last_price = price;
        view.priced_at = position.priced_at;
        view.entry_qty = position.qty;
        if price is not None {
            view.market_value = price * position.qty;
            view.pnl = (price - position.avg_entry_price) * position.qty;
            view.pnl_pct = price / position.avg_entry_price - 1.0 if position.avg_entry_price > 0 else None;
            view.weight = view.market_value / equity if equity else None;
            if position.stop_price > 0 {
                view.stop_distance = 1.0 - position.stop_price / price;
            }
        }
        return view;
    }
    view.closed_at = position.closed_at;
    view.exit_price = position.exit_price or None;
    sold = 0;
    realized = 0.0;
    for o in sent {
        if o.ticker == position.ticker and o.side == OrderSide.SELL and position.opened_at <= (o.submitted_at or "") <= position.closed_at {
            for f in [o ->:FilledBy:->[?:Fill]] {
                sold += f.qty;
                realized += (f.price - position.avg_entry_price) * f.qty;
            }
        }
    }
    view.entry_qty = sold;
    if sold > 0 {
        view.pnl = realized;
        view.pnl_pct = realized / (position.avg_entry_price * sold) if position.avg_entry_price > 0 else None;
    } elif position.exit_price and position.avg_entry_price > 0 {
        view.pnl_pct = position.exit_price / position.avg_entry_price - 1.0;
    }
    return view;
}

"""An order with its fills, and the run whose decision placed it (none for a stop)."""
def order_view(o: Order) -> OrderView {
    fills = sorted([f for f in [o ->:FilledBy:->[?:Fill]]], key=lambda (f: Fill) { f.filled_at; });
    day = "";
    for rc in [o <-:Placed:<-[?:RiskCheck]] {
        for d in [rc <-:CheckedBy:<-[?:Decision]] {
            day = decision_day(d);
        }
    }
    return OrderView(
        client_order_id=o.client_order_id,
        ticker=o.ticker,
        purpose=o.purpose.value,
        side=o.side.value,
        qty=o.qty,
        order_type=o.order_type,
        time_in_force=o.time_in_force,
        status=o.status,
        submitted_at=o.submitted_at,
        limit_price=o.limit_price or None,
        stop_price=o.stop_price or None,
        filled_qty=o.filled_qty,
        filled_avg_price=o.filled_avg_price or None,
        updated_at=o.updated_at,
        reject_reason=o.reject_reason,
        run_day=day,
        decision_id=f"{day}/{o.ticker}" if day else "",
        broker_order_id=o.alpaca_order_id,
        fills=[FillView(qty=f.qty, price=f.price, filled_at=f.filled_at) for f in fills]
    );
}

# --- Performance ------------------------------------------------------------------------

def performance_view(portfolio: Portfolio) -> PerformanceView {
    marks = sorted_marks(marks_of(portfolio));
    baselines = baselines_of(portfolio);
    if not marks and not baselines {
        return PerformanceView(started=False);
    }
    starts = [b.start_day for b in baselines.values()];
    view = PerformanceView(started=True, start_day=min(starts) if starts else marks[0].day, starting_cash=portfolio.starting_cash);
    view.series.append(series("team", marks, portfolio.starting_cash));
    for kind in [BaselineKind.EQUAL_WEIGHT, BaselineKind.SPY] {
        b = baselines.get(kind);
        if b is not None {
            view.series.append(series(kind.value, sorted_marks(sim_marks(b)), b.starting_cash));
        }
    }
    return view;
}

"""One equity curve and its statistics, measured from `starting_cash`."""
def series(key: str, marks: list[DailyMark], starting_cash: float) -> Series {
    found = Series(key=key, label=SERIES_LABELS.get(key, key), points=[]);
    peak = starting_cash;
    worst = 0.0;
    before = starting_cash;
    returns: list[float] = [];
    for m in marks {
        peak = max(peak, m.equity);
        drawdown = 1.0 - m.equity / peak if peak > 0 else 0.0;
        worst = max(worst, drawdown);
        found.points.append(MarkPoint(day=m.day, equity=m.equity, drawdown=drawdown));
        if before > 0 {
            returns.append(m.equity / before - 1.0);
        }
        before = m.equity;
    }
    if marks and starting_cash > 0 {
        found.total_return = marks[-1].equity / starting_cash - 1.0;
        found.max_drawdown = worst;
    }
    if len(returns) >= 2 {
        spread = statistics.stdev(returns);
        found.volatility = spread * math.sqrt(TRADING_DAYS);
        found.sharpe = statistics.fmean(returns) / spread * math.sqrt(TRADING_DAYS) if spread > 0 else None;
    }
    return found;
}

# --- Runs -------------------------------------------------------------------------------

def runs_by_day(portfolio: Portfolio) -> dict[str, Run] {
    return {r.run_date: r for r in [portfolio ->:Ran:->[?:Run]]};
}

"""Each role's votes and hit rate over the last SPECIALIST_RUNS runs, and its most recent votes.
Counts come from each run's stored tally (analysis/scoring.jac `tally_run`); a run's votes are
read only while a role it has votes from still lacks recent ones, or when it has no tally yet
(today's run before the evening review). Reading every vote, thousands of nodes, held up every
other request for seconds."""
def specialist_summaries(portfolio: Portfolio) -> list[SpecialistSummaryView] {
    by_role = {s.value: SpecialistSummaryView(specialist=s.value) for s in SPECIALIST_ROLES};
    runs = runs_by_day(portfolio);
    recent_days = sorted(runs, reverse=True)[:SPECIALIST_RUNS];
    for row in by_role.values() {
        row.runs = len(recent_days);
    }
    for day in recent_days {
        tally = runs[day].specialist_tallies;
        short = [s for (s, row) in by_role.items() if len(row.recent) < RECENT_SPECIALIST_VOTES];
        if not tally or any(tally.get(s, [0])[0] > 0 for s in short) {
            votes = recent_votes(by_role, day, runs[day]);
            tally = tally or tally_votes(votes);
        }
        for (s, counts) in tally.items() {
            row = by_role.get(s);
            if row is not None and len(counts) == 3 {
                row.votes += counts[0];
                row.scored += counts[1];
                row.hits += counts[2];
            }
        }
    }
    for row in by_role.values() {
        row.hit_rate = row.hits / row.scored if row.scored else None;
    }
    # Calibration bands come from the stored evaluation (analysis/evaluation.jac `calibration`), so
    # this page and the Results page read the same numbers rather than binning votes twice.
    stored = latest_evaluation(portfolio);
    for found in (stored.specialists if stored is not None else []) {
        row = by_role.get(found.specialist);
        if row is None {
            continue;
        }
        for b in found.bins {
            if b.votes > 0 and b.confidence is not None and b.hit_rate is not None {
                row.calibration.append(CalibrationBinView(low=b.low, high=b.high, count=b.votes, mean_confidence=b.confidence, hit_rate=b.hit_rate));
            }
        }
    }
    return [by_role[s.value] for s in SPECIALIST_ROLES];
}

"""Read `run`'s votes in page order (by ticker, then role and sample), adding each to its role's
recent votes until the role has RECENT_SPECIALIST_VOTES. Returns every vote read."""
def recent_votes(by_role: dict[str, SpecialistSummaryView], day: str, run: Run) -> list[VoteRecord] {
    read: list[VoteRecord] = [];
    for cov in sorted([c for c in [run ->:Covers:->[?:Coverage]]], key=lambda (c: Coverage) { c.ticker; }) {
        for v in sorted([v for v in [cov ->:Voted:->[?:VoteRecord]]], key=lambda (v: VoteRecord) { (v.specialist.value, v.sample); }) {
            read.append(v);
            row = by_role.get(v.specialist.value);
            if row is not None and len(row.recent) < RECENT_SPECIALIST_VOTES {
                row.recent.append(SpecialistVoteView(
                    run_date=day, ticker=cov.ticker, sample=v.sample,
                    stance=v.body.stance.value, confidence=v.body.confidence,
                    rationale=v.body.rationale, scored_at=v.scored_at, hit=hit(v)
                ));
            }
        }
    }
    return read;
}

def first_of[T](items: list[T]) -> T | None {
    return items[0] if items else None;
}

def run_summaries(portfolio: Portfolio) -> list[RunSummary] {
    found: list[RunSummary] = [];
    runs = runs_by_day(portfolio);
    for day in sorted(runs, reverse=True)[:MAX_RUNS] {
        run = runs[day];
        summary = RunSummary(run_date=day, status=run.status.value, actions={});
        for cov in [run ->:Covers:->[?:Coverage]] {
            summary.covered += 1;
            for d in [cov ->:Decided:->[?:Decision]] {
                summary.actions[d.action.value] = summary.actions.get(d.action.value, 0) + 1;
                for rc in [d ->:CheckedBy:->[?:RiskCheck]] {
                    summary.trades += len([o for o in [rc ->:Placed:->[?:Order]] if o.filled_qty > 0]);
                }
            }
        }
        found.append(summary);
    }
    return found;
}

def macro_view(run: Run) -> MacroView | None {
    for m in [run ->:HasMacro:->[?:MacroRecord]] {
        view = MacroView(regime=m.body.regime.value, confidence=m.body.confidence, summary=m.body.summary, risks=m.body.risks);
        if m.inputs is not None {
            view.spy_close = m.inputs.spy_close;
            view.spy_sma_200 = m.inputs.spy_sma_200;
            view.spy_vol_20 = m.inputs.spy_vol_20;
        }
        return view;
    }
    return None;
}

def run_view(portfolio: Portfolio, run_date: str) -> RunView | None {
    runs = runs_by_day(portfolio);
    if not runs {
        return None;
    }
    days = sorted(runs);
    day = run_date or days[-1];
    run = runs.get(day);
    if run is None {
        return None;
    }
    at = days.index(day);
    view = RunView(
        run_date=day,
        status=run.status.value,
        mode=portfolio.mode.value,
        demo=portfolio.demo,
        reduced_mode=run.reduced_mode,
        started_at=run.started_at,
        finished_at=run.finished_at,
        executed_at=run.executed_at,
        reconciled_at=run.reconciled_at,
        execution_note=run.execution_note,
        summary=run.summary,
        model_requests=run.model_requests,
        prompt_tokens=run.prompt_tokens,
        completion_tokens=run.completion_tokens,
        macro=macro_view(run),
        policy_version=run.policy_version,
        action_log=run.action_log,
        previous_day=days[at - 1] if at > 0 else "",
        next_day=days[at + 1] if at + 1 < len(days) else ""
    );
    view.rows = sorted(
        [coverage_row(c) for c in [run ->:Covers:->[?:Coverage]]],
        key=lambda (r: CoverageRow) { (-(r.conviction or 0.0), r.ticker); }
    );
    (view.execution_summary, view.execution_detail) = execution_summary(run.execution_note, view.rows);
    return view;
}

"""An order's status in plain words: a refusal the executor recorded without sending reads "not
sent", Alpaca's refusal "broker rejected", and a status still working at the broker "working"."""
def order_word(status: str, reject_reason: str = "") -> str {
    if status == "rejected" and reject_reason.startswith("not sent") {
        return "not sent";
    }
    return ORDER_WORDS.get(status, "working");
}

def counted(n: int, noun: str) -> str {
    return f"{n} {noun}" + ("" if n == 1 else "s");
}

"""What the risk gate and the broker did with a run's decisions, in plain words, from the
executor's note (which counts the checks, held stocks the run did not cover among them) and the
rows' orders as they stand now: ("2 of 3 approved", "1 filled · 1 broker rejected"). An
empty note gives empty text, and a note this cannot read is shown as the executor wrote it."""
def execution_summary(note: str, rows: list[CoverageRow]) -> tuple[str, str] {
    if not note {
        return ("", "");
    }
    off = ORDERS_OFF.search(note);
    if off is not None {
        return (f"{counted(int(off.group(1)), 'check')}, none sent", "orders are turned off");
    }
    done = EXECUTED.match(note);
    if done is None {
        return (note[:1].upper() + note[1:], "");
    }
    (checks, approved) = (int(done.group(1)), int(done.group(2)));
    words: dict[str, int] = {};
    for r in rows {
        if r.order_status {
            word = order_word(r.order_status, r.order_reject_reason);
            words[word] = words.get(word, 0) + 1;
        }
    }
    detail = [f"{n} {word}" for (word, n) in words.items()];
    if not detail {
        detail.append("nothing sent");
    }
    if "market data gaps" in note {
        detail.append("market data gaps");
    }
    head = "No orders to check" if checks == 0 else f"{approved} of {checks} approved";
    return (head, " · ".join(detail));
}

def coverage_row(cov: Coverage) -> CoverageRow {
    row = CoverageRow(
        ticker=cov.ticker,
        sector=cov.sector,
        reason=cov.reason.value,
        reason_note=cov.reason_note,
        screen_score=cov.screen_score if cov.reason.value == "screen" else None,
        flag_reason=cov.flag_reason,
        last_close=cov.last_close or None
    );
    c = first_of([c for c in [cov ->:Concluded:->[?:ConsensusResult]]]);
    if c is not None {
        row.score = c.score;
        row.agreement = c.agreement;
        row.ci_low = c.ci_low;
        row.ci_high = c.ci_high;
        row.draft_action = c.draft_action.value;
    }
    d = first_of([d for d in [cov ->:Decided:->[?:Decision]]]);
    if d is None {
        return row;
    }
    row.action = d.action.value;
    row.conviction = d.conviction;
    row.downgraded = bool(d.downgrade_reason);
    row.forced_hold = bool(d.forced_hold_reason);
    rc = first_of([rc for rc in [d ->:CheckedBy:->[?:RiskCheck]]]);
    if rc is not None {
        row.gate_outcome = rc.outcome.value;
        row.requested_qty = rc.requested_qty;
        row.approved_qty = rc.approved_qty;
        failed = [r.rule for r in rc.rules if not r.passed];
        row.rejected_by = failed[-1] if failed else "";
        o = first_of([o for o in [rc ->:Placed:->[?:Order]]]);
        if o is not None {
            row.order_status = o.status;
            row.order_reject_reason = o.reject_reason;
            row.order_side = o.side.value;
            row.order_qty = o.qty;
            row.filled_qty = o.filled_qty;
            row.filled_avg_price = o.filled_avg_price or None;
        }
    }
    return row;
}

# --- Decision trail ---------------------------------------------------------------------

def trail_view(portfolio: Portfolio, run_date: str, ticker: str) -> TrailView | None {
    run = runs_by_day(portfolio).get(run_date);
    if run is None {
        return None;
    }
    covered = [c for c in [run ->:Covers:->[?:Coverage]]];
    cov = first_of([c for c in covered if c.ticker == ticker]);
    if cov is None {
        return None;
    }
    records = [r for r in [cov ->:Researched:->[?:ResearchRecord]]];
    view = TrailView(
        run_date=run_date,
        run_id=run_date,
        decision_id=f"{run_date}/{cov.ticker}",
        ticker=cov.ticker,
        sector=cov.sector,
        reason=cov.reason.value,
        run_status=run.status.value,
        mode=portfolio.mode.value,
        demo=portfolio.demo,
        reason_note=cov.reason_note,
        screen_score=cov.screen_score if cov.reason.value == "screen" else None,
        flag_reason=cov.flag_reason,
        fetch_errors=cov.fetch_errors,
        last_close=cov.last_close or None,
        atr_14=cov.atr_14,
        realized_vol_20=cov.realized_vol_20,
        volume_20=cov.volume_20,
        sessions_to_earnings=cov.sessions_to_earnings,
        research=research_views(records),
        macro=macro_view(run),
        tickers=[r.ticker for r in sorted([coverage_row(c) for c in covered], key=lambda (r: CoverageRow) { (-(r.conviction or 0.0), r.ticker); })],
        disclaimer=DISCLAIMER
    );
    c = first_of([c for c in [cov ->:Concluded:->[?:ConsensusResult]]]);
    if c is not None {
        view.consensus = ConsensusView(score=c.score, agreement=c.agreement, ci_low=c.ci_low, ci_high=c.ci_high, draft_action=c.draft_action.value, samples_used=c.samples_used, samples_dropped=c.samples_dropped);
    }
    sources = packet_sources(records, first_of([m for m in [run ->:HasMacro:->[?:MacroRecord]]]), cov.ticker, run_date);
    view.specialists = specialist_views([v for v in [cov ->:Voted:->[?:VoteRecord]]], c.weights if c is not None else {}, sources, cov.analysis_errors);
    d = first_of([d for d in [cov ->:Decided:->[?:Decision]]]);
    if d is None {
        return view;
    }
    view.decision = DecisionView(
        action=d.action.value,
        conviction=d.conviction,
        thesis=d.thesis,
        risks=d.risks,
        exit_condition=d.exit_condition,
        time_stop=d.time_stop,
        arbiter_verdict=d.arbiter_verdict,
        downgrade_reason=d.downgrade_reason,
        forced_hold_reason=d.forced_hold_reason,
        model=d.model,
        policy_version=d.policy_version,
        policy_notes=d.policy_notes,
        policy_skipped=d.policy_skipped
    );
    orders: list[Order] = [];
    rc = first_of([rc for rc in [d ->:CheckedBy:->[?:RiskCheck]]]);
    if rc is not None {
        view.gate = GateView(
            outcome=rc.outcome.value,
            side=rc.side.value if rc.side is not None else "",
            purpose=rc.purpose.value if rc.purpose is not None else "",
            requested_qty=rc.requested_qty,
            approved_qty=rc.approved_qty,
            checked_at=rc.checked_at,
            price=rc.price or None,
            stop_distance=rc.stop_distance or None,
            gate_version=rc.gate_version,
            rules=[RuleView(rule=r.rule, passed=r.passed, detail=r.detail, qty_before=r.qty_before, qty_after=r.qty_after) for r in rc.rules]
        );
        orders.extend(o for o in [rc ->:Placed:->[?:Order]]);
    }
    opened = first_of([p for p in [d <-:OpenedBy:<-[?:Position]]]);
    if opened is not None {
        orders.extend(o for o in [opened ->:StoppedBy:->[?:Order]]);
        view.position = position_view(opened, portfolio_equity(portfolio), [o for o in [portfolio ->:Sent:->[?:Order]]]);
    }
    view.orders = [order_view(o) for o in sorted(orders, key=lambda (o: Order) { o.submitted_at; })];
    return view;
}

def portfolio_equity(portfolio: Portfolio) -> float | None {
    marks = marks_of(portfolio);
    return marks[max(marks)].equity if marks else None;
}

"""Research reports in domain order, each domain's first report before its follow-ups."""
def research_views(records: list[ResearchRecord]) -> list[ResearchView] {
    found: list[ResearchView] = [];
    for domain in DOMAIN_ORDER {
        mine = sorted([r for r in records if r.domain == domain], key=lambda (r: ResearchRecord) { (bool(r.followup_question), r.as_of); });
        for r in mine {
            found.append(ResearchView(
                domain=domain.value,
                view=r.body.view.value,
                confidence=r.body.confidence,
                summary=r.body.summary,
                evidence=[evidence_view(e) for e in r.body.evidence],
                risks=r.body.risks,
                data_gaps=r.body.data_gaps,
                model=r.model,
                as_of=r.as_of,
                followup_question=r.followup_question
            ));
        }
    }
    return found;
}

def evidence_view(e: Evidence) -> EvidenceView {
    return EvidenceView(claim=e.claim, source_url=e.source_url, published=e.published, host=urlsplit(e.source_url).hostname or "", published_at=utc_stamp(e.published));
}

"""A source's stamp as an ISO timestamp in UTC when it carries a time of day, or "" for a bare
date or anything unreadable. A stamp with no zone is taken as UTC, as the app stores times."""
def utc_stamp(text: str) -> str {
    text = text.strip();
    if len(text) < 16 or text[10] not in "T " {
        return "";
    }
    try {
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"));
    } except ValueError {
        return "";
    }
    if moment.tzinfo is None {
        moment = moment.replace(tzinfo=timezone.utc);
    }
    return moment.astimezone(timezone.utc).isoformat();
}

"""Each specialist's evidence packet as the panel read it (agents/specialists.jac), so a vote's
cited positions name their evidence: the newest report per domain, since a follow-up replaces
the report it follows, and the run's macro report."""
def packet_sources(records: list[ResearchRecord], macro: MacroRecord | None, ticker: str, run_date: str) -> dict[str, list[EvidenceView]] {
    newest: dict[Domain, ResearchReport] = {};
    for r in sorted(records, key=lambda (r: ResearchRecord) { bool(r.followup_question); }) {
        newest[r.domain] = r.body;
    }
    body = macro.body if macro is not None else None;
    return {s.value: [evidence_view(e) for e in packet(s, ticker, run_date, newest, body).evidence] for s in SPECIALIST_ROLES};
}

"""Each role's dropped samples, (sample, error) in the order recorded, from a coverage's
`analysis_errors`."""
def dropped_samples(errors: list[str]) -> dict[str, list[tuple[int, str]]] {
    found: dict[str, list[tuple[int, str]]] = {};
    for line in errors {
        m = SAMPLE_ERROR.match(line);
        if m is not None {
            found.setdefault(m.group(1), []).append((int(m.group(2)), m.group(3)));
        }
    }
    return found;
}

"""All five specialists in panel order, each with its samples, its mean signed score over the
samples that count, its weight, the evidence each sample cited, and why any sample was dropped
(`errors` is the coverage's `analysis_errors`). A specialist with no sample that counts scores 0
and has no weight, and its `status` says whether it abstained for want of evidence, failed, or
never ran (SpecialistView)."""
def specialist_views(votes: list[VoteRecord], weights: dict[str, float], sources: dict[str, list[EvidenceView]] | None = None, errors: list[str] | None = None) -> list[SpecialistView] {
    sources = sources or {};
    dropped = dropped_samples(errors or []);
    found: list[SpecialistView] = [];
    for s in SPECIALIST_ROLES {
        mine = sorted([v for v in votes if v.specialist == s], key=lambda (v: VoteRecord) { v.sample; });
        failed = sorted(dropped.get(s.value, []));
        samples = [
            SampleView(
                sample=v.sample,
                stance=v.body.stance.value,
                confidence=v.body.confidence,
                signed=signed_score(v.body),
                horizon_days=v.body.horizon_days,
                rationale=v.body.rationale,
                cited=v.body.cited_evidence,
                sources=[sources[s.value][i] for i in v.body.cited_evidence if s.value in sources and 0 <= i < len(sources[s.value])],
                excess_return=v.excess_return,
                hit=hit(v),
                abstained=abstains(v.body),
                gaps=v.body.cited_gaps
            )
            for v in mine
        ];
        scored = [x.signed for x in samples if not x.abstained];
        status = "voted";
        if not scored {
            if samples or (failed and all(text == NO_EVIDENCE for (_, text) in failed)) {
                status = "abstained";
            } elif failed {
                status = "failed";
            } else {
                status = "not_run";
            }
        }
        found.append(SpecialistView(
            specialist=s.value,
            score=statistics.fmean(scored) if scored else 0.0,
            weight=weights.get(s.value),
            samples=samples,
            status=status,
            errors=[f"Sample {n + 1}: {text}" for (n, text) in failed]
        ));
    }
    return found;
}

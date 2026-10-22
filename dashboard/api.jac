"""The dashboard's endpoints (TDD §10): public, read-only views of the team graph on
root.shared.

Each endpoint finds the team portfolio without creating it, walks the stored graph, and
returns a view from models/views.jac. Nothing here writes, calls a model, or reaches Alpaca,
so a page loads from what the pipeline already stored and cannot spend the request budget
(TDD §10, design notes). The builders take the portfolio as an argument, so tests can run
them on any graph; the endpoints only pick the team's.

Views come through the read cache in dashboard/cache.jac, and refresh_job rebuilds the
portfolio, performance, and run list every minute, so a page shows the graph as of at most
a minute or two ago.
"""
import math;
import statistics;
import from urllib.parse { urlsplit }
import from action.baselines { baselines_of, sim_marks }
import from action.insights { DISCLAIMER }
import from action.reconcile { marks_of }
import from dashboard.cache { VIEWS }
import from analysis.consensus { signed_score }
import from analysis.scoring { hit }
import from models.agents { Domain, Specialist }
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
    TrailView
}
import from run.guard { TEAM_PORTFOLIO }

glob TRADING_DAYS: int = 252;
glob RECENT_ORDERS: int = 60;
glob RECENT_CLOSED: int = 40;
glob MAX_RUNS: int = 250;
glob SERIES_LABELS: dict[str, str] = {"team": "Team portfolio", "equal_weight": "Equal-weight shortlist", "spy": "SPY buy-and-hold"};
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

"""A cache key for one of the team portfolio's views; the portfolio's id keeps graphs apart."""
def view_key(team: Portfolio, *parts: str) -> str {
    return ":".join([jid(team)] + list(parts));
}

"""The team portfolio at its last mark, with its positions and its most recently submitted orders."""
def:pub get_portfolio -> PortfolioView {
    team = find_team();
    if team is None {
        return PortfolioView(name=TEAM_PORTFOLIO, mode="insight", started=False);
    }
    return VIEWS.get(view_key(team, "portfolio"), portfolio_view, team);
}

"""The team portfolio's daily equity beside both forward-test baselines."""
def:pub get_performance -> PerformanceView {
    team = find_team();
    if team is None {
        return PerformanceView(started=False);
    }
    return VIEWS.get(view_key(team, "performance"), performance_view, team);
}

"""The team's runs, newest first."""
def:pub list_runs -> list[RunSummary] {
    team = find_team();
    if team is None {
        return [];
    }
    return VIEWS.get(view_key(team, "runs"), run_summaries, team);
}

"""The run for `run_date`, or the newest run when it is empty; None when there is none."""
def:pub get_run(run_date: str = "") -> RunView | None {
    team = find_team();
    if team is None {
        return None;
    }
    return VIEWS.get(view_key(team, "run", run_date), run_view, team, run_date);
}

"""One ticker's trail in the run for `run_date`, or None when the run did not cover it."""
def:pub get_decision_trail(run_date: str, ticker: str) -> TrailView | None {
    team = find_team();
    if team is None {
        return None;
    }
    symbol = ticker.strip().upper();
    return VIEWS.get(view_key(team, "trail", run_date, symbol), trail_view, team, run_date, symbol);
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
    }
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
        action_log=run.action_log,
        previous_day=days[at - 1] if at > 0 else "",
        next_day=days[at + 1] if at + 1 < len(days) else ""
    );
    view.rows = sorted(
        [coverage_row(c) for c in [run ->:Covers:->[?:Coverage]]],
        key=lambda (r: CoverageRow) { (-(r.conviction or 0.0), r.ticker); }
    );
    return view;
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
    view = TrailView(
        run_date=run_date,
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
        research=research_views([r for r in [cov ->:Researched:->[?:ResearchRecord]]]),
        macro=macro_view(run),
        tickers=[r.ticker for r in sorted([coverage_row(c) for c in covered], key=lambda (r: CoverageRow) { (-(r.conviction or 0.0), r.ticker); })],
        disclaimer=DISCLAIMER
    );
    c = first_of([c for c in [cov ->:Concluded:->[?:ConsensusResult]]]);
    if c is not None {
        view.consensus = ConsensusView(score=c.score, agreement=c.agreement, ci_low=c.ci_low, ci_high=c.ci_high, draft_action=c.draft_action.value, samples_used=c.samples_used, samples_dropped=c.samples_dropped);
    }
    view.specialists = specialist_views([v for v in [cov ->:Voted:->[?:VoteRecord]]], c.weights if c is not None else {});
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
        model=d.model
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
                evidence=[EvidenceView(claim=e.claim, source_url=e.source_url, published=e.published, host=urlsplit(e.source_url).hostname or "") for e in r.body.evidence],
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

"""Each specialist's samples in panel order, with its mean signed score and its weight."""
def specialist_views(votes: list[VoteRecord], weights: dict[str, float]) -> list[SpecialistView] {
    found: list[SpecialistView] = [];
    for s in list(Specialist) {
        mine = sorted([v for v in votes if v.specialist == s], key=lambda (v: VoteRecord) { v.sample; });
        if not mine {
            continue;
        }
        samples = [
            SampleView(
                sample=v.sample,
                stance=v.body.stance.value,
                confidence=v.body.confidence,
                signed=signed_score(v.body),
                horizon_days=v.body.horizon_days,
                rationale=v.body.rationale,
                cited=v.body.cited_evidence,
                excess_return=v.excess_return,
                hit=hit(v)
            )
            for v in mine
        ];
        found.append(SpecialistView(specialist=s.value, score=statistics.fmean(x.signed for x in samples), weight=weights.get(s.value), samples=samples));
    }
    return found;
}

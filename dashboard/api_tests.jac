"""The dashboard's views (dashboard/api.jac) on a portfolio traded against the fake broker: a
buy that fills and gets its stop, a mark, an exit on the next run, and the research, votes,
and consensus behind the first decision."""
import from datetime { datetime, timezone }
import from action.executor { execute_run, keep_stops, sync_orders }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from action.reconcile { marks_of, reconcile }
import from dashboard.api { performance_view, portfolio_view, run_summaries, run_view, series, trail_view }
import from models.agents { Domain, Evidence, ResearchReport, Specialist, Stance, Vote }
import from models.graph {
    Concluded,
    ConsensusResult,
    Coverage,
    Covers,
    DailyMark,
    Portfolio,
    Researched,
    ResearchRecord,
    Run,
    TradeAction,
    VoteRecord,
    Voted
}
import from tests.fakes.broker_server { FakeBroker }

glob DAY1: str = "2026-10-21";
glob DAY2: str = "2026-10-22";
glob NOW1: datetime = datetime(2026, 10, 21, 13, 45, tzinfo=timezone.utc);
glob CLOSE1: datetime = datetime(2026, 10, 21, 20, 30, tzinfo=timezone.utc);
glob NOW2: datetime = datetime(2026, 10, 22, 13, 45, tzinfo=timezone.utc);
glob CLOSE2: datetime = datetime(2026, 10, 22, 20, 30, tzinfo=timezone.utc);

def coverage_of(run: Run, ticker: str) -> Coverage {
    return [c for c in [run ->:Covers:->[?:Coverage]] if c.ticker == ticker][0];
}

"""The panel's evidence for AAA on the first run: one market report, two specialists with
two samples each, and the consensus they produced."""
def add_panel(run: Run) {
    cov = coverage_of(run, "AAA");
    cov +>:Researched():+> ResearchRecord(ticker="AAA", domain=Domain.NEWS, as_of="2026-10-21T12:00:00+00:00", model="m", body=ResearchReport(summary="Quiet.", view=Stance.HOLD, confidence=0.5));
    cov +>:Researched():+> ResearchRecord(
        ticker="AAA",
        domain=Domain.MARKET,
        as_of="2026-10-21T12:00:00+00:00",
        model="m",
        body=ResearchReport(summary="Uptrend.", view=Stance.BUY, confidence=0.7, evidence=[Evidence(claim="Above its 50-day average.", source_url="https://data.alpaca.markets/v2/stocks/bars", published="2026-10-20")])
    );
    for (s, stances) in [(Specialist.TECHNICAL, [Stance.BUY, Stance.STRONG_BUY]), (Specialist.FUNDAMENTALS, [Stance.SELL, Stance.HOLD])] {
        for (i, stance) in enumerate(stances) {
            cov +>:Voted():+> VoteRecord(ticker="AAA", specialist=s, sample=i, model="m", body=Vote(stance=stance, confidence=0.8, horizon_days=5, rationale="Because.", cited_evidence=[1]));
        }
    }
    cov +>:Concluded():+> ConsensusResult(ticker="AAA", score=0.2, agreement=0.5, ci_low=-0.1, ci_high=0.5, draft_action=TradeAction.BUY, weights={"technical": 0.6, "fundamentals": 0.4}, samples_used=4);
}

"""Day one: buy 40 AAA at 100, stop at 96, marked at 102. Day two: sell them all at 105."""
def traded(fake: FakeBroker) -> tuple[Portfolio, Run, Run] {
    broker = broker_for(fake);
    portfolio = team();
    fake.set_price("AAA", 100.0);
    first = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5), Call(ticker="BBB", action=TradeAction.HOLD, conviction=0.1)]);
    add_panel(first);
    execute_run(portfolio, first, broker, NOW1, market({"AAA": 100.0, "BBB": 50.0}, NOW1));
    fake.fill(f"{DAY1}-AAA-entry", 0, 100.0);
    sync_orders(portfolio, broker, NOW1);
    keep_stops(portfolio, broker, NOW1);
    fake.set_price("AAA", 102.0);
    reconcile(portfolio, broker, CLOSE1, DAY1);
    second = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.SELL)]);
    execute_run(portfolio, second, broker, NOW2, market({"AAA": 105.0}, NOW2));
    fake.fill(f"{DAY2}-AAA-exit", 0, 105.0);
    sync_orders(portfolio, broker, NOW2);
    reconcile(portfolio, broker, CLOSE2, DAY2);
    return (portfolio, first, second);
}

test "an open position is valued at its last mark and linked to the decision that opened it" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        execute_run(portfolio, finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5)]), broker, NOW1, market({"AAA": 100.0}, NOW1));
        fake.fill(f"{DAY1}-AAA-entry", 0, 100.0);
        sync_orders(portfolio, broker, NOW1);
        keep_stops(portfolio, broker, NOW1);
        fake.set_price("AAA", 102.0);
        mark = reconcile(portfolio, broker, CLOSE1, DAY1);
        view = portfolio_view(portfolio);
        assert view.started and view.equity == mark.equity and view.last_day == DAY1 and view.sessions == 1;
        assert abs(view.total_pnl - (mark.equity - 100000.0)) < 1e-9 and view.bypasses == 0;
        p = view.positions[0];
        assert (p.ticker, p.qty, p.last_price, p.decision_day, p.thesis) == ("AAA", 40, 102.0, DAY1, "AAA thesis.");
        assert p.pnl == 80.0 and abs(p.pnl_pct - 0.02) < 1e-12 and abs(p.weight - 4080.0 / mark.equity) < 1e-12;
        assert p.stop_price == 96.0 and abs(p.stop_distance - (1.0 - 96.0 / 102.0)) < 1e-12;
        by_id = {o.client_order_id: o for o in view.orders};
        bought = by_id[f"{DAY1}-AAA-entry"];
        assert bought.run_day == DAY1 and bought.filled_qty == 40 and [(f.qty, f.price) for f in bought.fills] == [(40, 100.0)];
        stops = [o for o in view.orders if o.purpose == "stop"];
        assert len(stops) == 1 and stops[0].run_day == "" and stops[0].stop_price == 96.0;
    } finally {
        fake.stop();
    }
}

test "a closed position's P&L is realized from the fills of the sale that closed it" {
    fake = FakeBroker();
    try {
        (portfolio, _, _) = traded(fake);
        view = portfolio_view(portfolio);
        assert view.positions == [] and len(view.closed) == 1;
        c = view.closed[0];
        assert (c.ticker, c.entry_qty, c.exit_price, c.pnl) == ("AAA", 40, 105.0, 200.0);
        assert abs(c.pnl_pct - 0.05) < 1e-12 and c.closed_at and c.decision_day == DAY1;
        marks = marks_of(portfolio);
        assert view.day_pnl == marks[DAY2].equity - marks[DAY1].equity and view.sessions == 2;
    } finally {
        fake.stop();
    }
}

test "a run lists every covered ticker by conviction with its consensus, gate outcome, and order" {
    fake = FakeBroker();
    try {
        (portfolio, _, _) = traded(fake);
        view = run_view(portfolio, DAY1);
        assert view is not None and view.next_day == DAY2 and view.previous_day == "";
        macro = view.macro;
        assert [r.ticker for r in view.rows] == ["AAA", "BBB"] and macro is not None and macro.regime == "NEUTRAL";
        aaa = view.rows[0];
        assert (aaa.action, aaa.score, aaa.ci_low, aaa.ci_high, aaa.draft_action) == ("BUY", 0.2, -0.1, 0.5, "BUY");
        assert (aaa.gate_outcome, aaa.approved_qty, aaa.order_side, aaa.filled_qty, aaa.filled_avg_price) == ("approved", 40, "buy", 40, 100.0);
        assert view.rows[1].order_status == "";
        latest = run_view(portfolio, "");
        assert latest is not None and latest.run_date == DAY2 and latest.previous_day == DAY1;
        assert run_view(portfolio, "2026-01-01") is None;
        summaries = run_summaries(portfolio);
        assert [(s.run_date, s.covered, s.trades) for s in summaries] == [(DAY2, 1, 1), (DAY1, 2, 1)];
        assert summaries[1].actions == {"BUY": 1, "HOLD": 1};
    } finally {
        fake.stop();
    }
}

test "a decision trail runs from research and votes through the gate to the orders and the position" {
    fake = FakeBroker();
    try {
        (portfolio, _, _) = traded(fake);
        trail = trail_view(portfolio, DAY1, "AAA");
        assert trail is not None and trail.tickers == ["AAA", "BBB"] and trail.disclaimer;
        assert [r.domain for r in trail.research] == ["market", "news"];
        assert trail.research[0].evidence[0].host == "data.alpaca.markets";
        assert [(s.specialist, s.weight) for s in trail.specialists] == [("fundamentals", 0.4), ("technical", 0.6)];
        tech = trail.specialists[1];
        assert [x.signed for x in tech.samples] == [0.4, 0.8] and abs(tech.score - 0.6) < 1e-12;
        (consensus, decision, gate) = (trail.consensus, trail.decision, trail.gate);
        assert consensus is not None and decision is not None and gate is not None;
        assert consensus.samples_used == 4 and decision.action == "BUY";
        assert gate.outcome == "approved" and gate.rules and all(r.passed for r in gate.rules);
        assert [o.purpose for o in trail.orders] == ["entry", "stop"];
        position = trail.position;
        assert position is not None and position.closed_at and position.pnl == 200.0;
        assert trail_view(portfolio, DAY1, "ZZZ") is None and trail_view(portfolio, "2026-01-01", "AAA") is None;
    } finally {
        fake.stop();
    }
}

test "a series measures return, drawdown, and Sharpe from the starting balance" {
    marks = [
        DailyMark(day="2026-10-21", equity=101000.0, cash=0.0, positions_value=0.0, peak_equity=0.0, marked_at=""),
        DailyMark(day="2026-10-22", equity=99990.0, cash=0.0, positions_value=0.0, peak_equity=0.0, marked_at=""),
        DailyMark(day="2026-10-23", equity=102000.0, cash=0.0, positions_value=0.0, peak_equity=0.0, marked_at="")
    ];
    s = series("team", marks, 100000.0);
    assert s.label == "Team portfolio" and [p.day for p in s.points] == ["2026-10-21", "2026-10-22", "2026-10-23"];
    assert abs(s.total_return - 0.02) < 1e-12 and abs(s.max_drawdown - 0.01) < 1e-12;
    assert s.sharpe is not None and s.sharpe > 0 and s.volatility > 0;
    one = series("spy", marks[:1], 100000.0);
    assert one.sharpe is None and abs(one.total_return - 0.01) < 1e-12;
    assert series("team", [], 0.0).total_return is None;
}

test "a portfolio that has not started shows no figures" {
    portfolio = team();
    view = portfolio_view(portfolio);
    assert not view.started and view.equity is None and view.positions == [] and view.orders == [];
    assert not performance_view(portfolio).started and run_view(portfolio, "") is None;
}

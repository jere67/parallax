"""The dashboard's views (dashboard/api.jac) on a portfolio traded against the fake broker: a
buy that fills and gets its stop, a mark, an exit on the next run, and the research, votes,
and consensus behind the first decision."""
import from datetime { datetime, timezone }
import from action.executor { execute_run, keep_stops, sync_orders }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from action.reconcile { marks_of, reconcile }
import from analysis.evaluation { evaluate, record_evaluation }
import from agents.specialists { NO_EVIDENCE }
import from dashboard.api {
    execution_summary,
    performance_view,
    portfolio_view,
    refresh_specialists,
    run_summaries,
    run_view,
    series,
    specialist_summaries,
    specialist_views,
    trail_view,
    utc_stamp,
    view_key
}
import from dashboard.cache { VIEWS }
import from models.agents { Domain, Evidence, ResearchReport, Specialist, Stance, Vote }
import from models.views { CoverageRow }
import from models.graph {
    CheckedBy,
    Concluded,
    ConsensusResult,
    Coverage,
    Covers,
    DailyMark,
    Decided,
    Decision,
    Order,
    Placed,
    Portfolio,
    Researched,
    ResearchRecord,
    RiskCheck,
    RiskOutcome,
    Run,
    Sent,
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
        body=ResearchReport(summary="Uptrend.", view=Stance.BUY, confidence=0.7, evidence=[
            Evidence(claim="Above its 50-day average.", source_url="https://data.alpaca.markets/v2/stocks/bars", published="2026-10-20"),
            Evidence(claim="An upgrade this morning.", source_url="https://data.alpaca.markets/v1beta1/news", published="2026-10-21T09:05:00-04:00")
        ])
    );
    for (s, stances) in [(Specialist.TECHNICAL, [Stance.BUY, Stance.STRONG_BUY]), (Specialist.FUNDAMENTALS, [Stance.SELL, Stance.HOLD])] {
        for (i, stance) in enumerate(stances) {
            cov +>:Voted():+> VoteRecord(ticker="AAA", specialist=s, sample=i, model="m", body=Vote(stance=stance, confidence=0.8, horizon_days=5, rationale="Because.", cited_evidence=[0]));
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

test "specialist summaries count scored directional votes and link recent output" {
    fake = FakeBroker();
    try {
        (portfolio, first, _) = traded(fake);
        cov = coverage_of(first, "AAA");
        votes = [v for v in [cov ->:Voted:->[?:VoteRecord]]];
        for v in votes {
            v.scored_at = "2026-10-29T20:30:00+00:00";
            v.excess_return = 0.05;
        }
        record_evaluation(portfolio, evaluate(portfolio, [DAY1, DAY2], CLOSE2));
        by_role = {s.specialist: s for s in specialist_summaries(portfolio)};
        assert len(by_role) == 5;
        technical = by_role["technical"];
        assert (technical.runs, technical.votes, technical.scored, technical.hits, technical.hit_rate) == (2, 2, 2, 2, 1.0);
        # The bands are the stored evaluation's, so this page and the Results page agree.
        assert len(technical.calibration) == 1;
        assert (technical.calibration[0].count, technical.calibration[0].mean_confidence, technical.calibration[0].hit_rate) == (2, 0.8, 1.0);
        assert [(v.run_date, v.ticker, v.sample) for v in technical.recent] == [(DAY1, "AAA", 0), (DAY1, "AAA", 1)];
        fundamentals = by_role["fundamentals"];
        assert (fundamentals.votes, fundamentals.scored, fundamentals.hits, fundamentals.hit_rate) == (2, 1, 0, 0.0);
        assert len(fundamentals.calibration) == 1 and fundamentals.calibration[0].count == 1;
        assert fundamentals.recent[1].hit is None;
        assert by_role["macro"].votes == 0 and by_role["macro"].hit_rate is None;
    } finally {
        fake.stop();
    }
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
        assert (trail.run_id, trail.decision_id) == (DAY1, f"{DAY1}/AAA");
        assert [r.domain for r in trail.research] == ["market", "news"];
        assert trail.research[0].evidence[0].host == "data.alpaca.markets";
        # Each source keeps the stamp it was published with, and its time in UTC when it has one.
        assert [(e.published, e.published_at) for e in trail.research[0].evidence] == [("2026-10-20", ""), ("2026-10-21T09:05:00-04:00", "2026-10-21T13:05:00+00:00")];
        assert trail.research[0].as_of == "2026-10-21T12:00:00+00:00";
        # Every specialist is shown, and one the run never asked says so rather than vanishing.
        assert [(s.specialist, s.weight, s.status) for s in trail.specialists] == [
            ("fundamentals", 0.4, "voted"), ("technical", 0.6, "voted"), ("news", None, "not_run"), ("macro", None, "not_run"), ("flow", None, "not_run")
        ];
        tech = trail.specialists[1];
        assert [x.signed for x in tech.samples] == [0.4, 0.8] and abs(tech.score - 0.6) < 1e-12;
        # The technical specialist reads the market report, so its cited positions name that evidence.
        first = tech.samples[0];
        assert first.sources and len(first.sources) == len(first.cited);
        assert first.sources[0].claim == trail.research[0].evidence[first.cited[0]].claim;
        (consensus, decision, gate) = (trail.consensus, trail.decision, trail.gate);
        assert consensus is not None and decision is not None and gate is not None;
        assert consensus.samples_used == 4 and decision.action == "BUY";
        assert gate.outcome == "approved" and gate.rules and all(r.passed for r in gate.rules);
        assert gate.checked_at == NOW1.isoformat();
        assert [o.purpose for o in trail.orders] == ["entry", "stop"];
        # The entry carries the trail's decision ID and the client order ID the broker shows; the
        # stop belongs to the position, not to a decision.
        (placed, stop) = (trail.orders[0], trail.orders[1]);
        assert (placed.client_order_id, placed.decision_id, placed.run_day) == (f"{DAY1}-AAA-entry", trail.decision_id, DAY1);
        assert placed.broker_order_id and placed.submitted_at == NOW1.isoformat() and [f.filled_at for f in placed.fills] != [];
        assert stop.client_order_id.startswith("AAA-") and stop.decision_id == "";
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
    assert s.label == "Your agent" and [p.day for p in s.points] == ["2026-10-21", "2026-10-22", "2026-10-23"];
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

test "a Flow sample that cites only data gaps shows as abstained and leaves Flow's score" {
    def record(sample: int, body: Vote) -> VoteRecord {
        return VoteRecord(ticker="AAA", specialist=Specialist.FLOW, sample=sample, model="m", body=body);
    }
    gap = Vote(stance=Stance.HOLD, confidence=0.5, horizon_days=10, rationale="No insider data.", cited_gaps=["no insider data"]);
    buy = Vote(stance=Stance.BUY, confidence=0.8, horizon_days=10, rationale="Insiders bought.", cited_evidence=[0]);
    mixed = specialist_views([record(0, gap), record(1, buy)], {"flow": 1.0})[4];
    assert mixed.specialist == "flow" and mixed.status == "voted";
    assert [x.abstained for x in mixed.samples] == [True, False];
    assert [x.gaps for x in mixed.samples] == [["no insider data"], []];
    assert abs(mixed.score - 0.4) < 1e-12 and mixed.weight == 1.0;
    silent = specialist_views([record(0, gap), record(1, gap)], {})[4];
    assert silent.score == 0.0 and silent.weight is None and all(x.abstained for x in silent.samples);
    assert silent.status == "abstained";
}

test "every specialist shows: voted, abstained for want of evidence, failed with its errors, or not run" {
    def record(s: Specialist, sample: int, body: Vote) -> VoteRecord {
        return VoteRecord(ticker="AAA", specialist=s, sample=sample, model="m", body=body);
    }
    buy = Vote(stance=Stance.BUY, confidence=0.8, horizon_days=10, rationale="Uptrend.", cited_evidence=[0]);
    neutral = Vote(stance=Stance.HOLD, confidence=0.6, horizon_days=10, rationale="Balanced.", cited_evidence=[0]);
    gap = Vote(stance=Stance.HOLD, confidence=0.5, horizon_days=10, rationale="No insider data.", cited_gaps=["no insider data"]);
    timeout = "Timeout: the model did not answer within 60 seconds";
    errors = [
        f"technical sample 1: {timeout}",
        f"news sample 0: {timeout}",
        f"news sample 1: RateLimitError: 429 Too Many Requests",
        f"fundamentals sample 0: {NO_EVIDENCE}",
        f"fundamentals sample 1: {NO_EVIDENCE}"
    ];
    votes = [record(Specialist.TECHNICAL, 0, buy), record(Specialist.MACRO, 0, neutral), record(Specialist.FLOW, 0, gap), record(Specialist.FLOW, 1, gap)];
    by_role = {s.specialist: s for s in specialist_views(votes, {"technical": 0.5, "macro": 0.5}, None, errors)};
    assert list(by_role) == ["fundamentals", "technical", "news", "macro", "flow"];
    # A specialist with a counted sample voted, and says why its other sample was dropped.
    tech = by_role["technical"];
    assert (tech.status, tech.weight, tech.errors) == ("voted", 0.5, [f"Sample 2: {timeout}"]);
    # A neutral Hold is a vote: it counts, scores zero, and is not an abstention.
    macro = by_role["macro"];
    assert (macro.status, macro.score, macro.samples[0].abstained) == ("voted", 0.0, False);
    # Missing evidence is an abstention, whether the samples cited only gaps or none were drawn.
    assert by_role["flow"].status == "abstained" and all(x.abstained for x in by_role["flow"].samples);
    fundamentals = by_role["fundamentals"];
    assert (fundamentals.status, fundamentals.samples, fundamentals.weight) == ("abstained", [], None);
    assert fundamentals.errors == [f"Sample 1: {NO_EVIDENCE}", f"Sample 2: {NO_EVIDENCE}"];
    # A specialist whose every sample failed is a failure, with each error, not a gap in the panel.
    news = by_role["news"];
    assert (news.status, news.samples, news.score) == ("failed", [], 0.0);
    assert news.errors == [f"Sample 1: {timeout}", "Sample 2: RateLimitError: 429 Too Many Requests"];
    # With no votes and no errors, every specialist is shown as not run.
    assert [s.status for s in specialist_views([], {})] == ["not_run"] * 5;
}

test "a failed specialist's errors reach the trail from the coverage's stored analysis errors" {
    fake = FakeBroker();
    try {
        (portfolio, first, _) = traded(fake);
        cov = coverage_of(first, "AAA");
        cov.analysis_errors = ["news sample 0: Timeout: no answer", "news sample 1: Timeout: no answer"];
        trail = trail_view(portfolio, DAY1, "AAA");
        assert trail is not None;
        news = [s for s in trail.specialists if s.specialist == "news"][0];
        assert (news.status, news.errors) == ("failed", ["Sample 1: Timeout: no answer", "Sample 2: Timeout: no answer"]);
    } finally {
        fake.stop();
    }
}

test "a decision the gate blocked has its check on the trail and no order, there or anywhere" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        fake.set_price("BBB", 50.0);
        # BBB reports earnings tomorrow, so the gate's blackout rule blocks its buy.
        run = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5), Call(ticker="BBB", action=TradeAction.BUY, conviction=0.5, earnings_in=1)]);
        execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0, "BBB": 50.0}, NOW1));
        blocked = trail_view(portfolio, DAY1, "BBB");
        assert blocked is not None;
        gate = blocked.gate;
        assert gate is not None and (gate.outcome, gate.approved_qty, gate.checked_at) == ("rejected", 0, NOW1.isoformat());
        assert [r.rule for r in gate.rules if not r.passed] == ["earnings blackout"];
        assert blocked.orders == [] and blocked.position is None;
        # No Order node exists for it: none placed under its check, none sent by the portfolio.
        decision = [d for d in [coverage_of(run, "BBB") ->:Decided:->[?:Decision]]][0];
        check = [rc for rc in [decision ->:CheckedBy:->[?:RiskCheck]]][0];
        assert check.outcome == RiskOutcome.REJECTED and [check ->:Placed:->] == [];
        assert [o.ticker for o in [portfolio ->:Sent:->[?:Order]]] == ["AAA"];
        assert fake.find(f"{DAY1}-BBB-entry") is None;
        # The approved one beside it went through, under its own decision's ID.
        sent = trail_view(portfolio, DAY1, "AAA");
        assert sent is not None and [(o.client_order_id, o.decision_id) for o in sent.orders] == [(f"{DAY1}-AAA-entry", f"{DAY1}/AAA")];
        # The run page says it in plain words, not the executor's raw line.
        view = run_view(portfolio, DAY1);
        assert view is not None and view.execution_note.startswith("2 checks, 1 approved");
        assert (view.execution_summary, view.execution_detail) == ("1 of 2 approved", "1 working");
        bbb = [r for r in view.rows if r.ticker == "BBB"][0];
        assert (bbb.gate_outcome, bbb.order_status) == ("rejected", "");
    } finally {
        fake.stop();
    }
}

test "the execution note reads in plain words, whatever the executor recorded" {
    def row(status: str, reason: str = "") -> CoverageRow {
        return CoverageRow(ticker="X", sector="", reason="screen", order_status=status, order_reject_reason=reason);
    }
    rows = [row("filled"), row("pending_new"), row("rejected", "insufficient buying power"), row("rejected", "not sent: its stop filled"), row("")];
    note = "4 checks, 4 approved; AAA buy 10 @ 100.30: pending_new; BBB buy 5 @ 50.15: rejected (insufficient buying power); CCC: not sent, its stop filled";
    assert execution_summary(note, rows) == ("4 of 4 approved", "1 filled · 1 working · 1 broker rejected · 1 not sent");
    assert execution_summary("1 checks, 0 approved; refused: AAA buy 40: earnings blackout", []) == ("0 of 1 approved", "nothing sent");
    assert execution_summary("0 checks, 0 approved", []) == ("No orders to check", "nothing sent");
    assert execution_summary("2 checks, 1 approved; market data gaps: SPY quote; AAA trade", [row("filled")]) == ("1 of 2 approved", "1 filled · market data gaps");
    assert execution_summary("orders are disabled (TRADING_AGENT_DISABLE_ORDERS=1); 3 checks recorded, nothing sent; refused: AAA buy 4: x", []) == ("3 checks, none sent", "orders are turned off");
    assert execution_summary("", []) == ("", "");
    assert execution_summary("something new", []) == ("Something new", "");
}

test "a source's stamp becomes a UTC time only when it carries a time of day" {
    assert utc_stamp("2026-10-21T09:05:00-04:00") == "2026-10-21T13:05:00+00:00";
    assert utc_stamp("2026-10-21T13:05:00Z") == "2026-10-21T13:05:00+00:00";
    assert utc_stamp("2026-10-21 13:05") == "2026-10-21T13:05:00+00:00";
    assert utc_stamp("2026-10-21") == "" and utc_stamp("") == "" and utc_stamp("Tuesday morning, 9:05") == "";
}

test "the refresh job rebuilds the specialists view only when a run finishes or its votes are scored" {
    fake = FakeBroker();
    try {
        (portfolio, first, _) = traded(fake);
        key = view_key(portfolio, "specialists");
        refresh_specialists(portfolio);
        built = VIEWS.entries[key].value;
        # A vote scored without the run recording it: the signature has not moved, so no rebuild.
        for v in [coverage_of(first, "AAA") ->:Voted:->[?:VoteRecord]] {
            v.scored_at = "2026-10-29T20:30:00+00:00";
            v.excess_return = 0.05;
        }
        refresh_specialists(portfolio);
        assert VIEWS.entries[key].value is built;
        first.votes_scored_at = "2026-10-29T20:30:00+00:00";
        refresh_specialists(portfolio);
        assert VIEWS.entries[key].value is not built;
    } finally {
        fake.stop();
    }
}

test "the specialists view counts runs from their stored tallies and reads votes only for recent ones" {
    fake = FakeBroker();
    try {
        (portfolio, first, _) = traded(fake);
        # A tally stands for the run's votes: its counts are used as they are.
        first.specialist_tallies = {"technical": [9, 4, 3]};
        technical = {s.specialist: s for s in specialist_summaries(portfolio)}["technical"];
        assert (technical.votes, technical.scored, technical.hits) == (9, 4, 3);
        assert [(v.run_date, v.sample) for v in technical.recent] == [(DAY1, 0), (DAY1, 1)];
        # A run whose tally has no votes from a role still short of recent ones is not read at all.
        first.specialist_tallies = {"flow": [0, 0, 0]};
        technical = {s.specialist: s for s in specialist_summaries(portfolio)}["technical"];
        assert technical.votes == 0 and technical.recent == [];
    } finally {
        fake.stop();
    }
}

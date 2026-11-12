"""The launch rehearsal (launch guide, item 4), offline: one reproducible paper-trading run, from
the morning run's votes to the orders, the evening's stored evaluation, and the report built from
it, with every failure left visible.

It reuses the Action exit run's three sessions (tests/runs/action_exit_run.jac) on a fake Alpaca
account, with two things going wrong on purpose:

- Thursday, every model is down, so no specialist answers.
- Friday, NVDA reports earnings the next session, so the risk gate refuses its buy.

The same flow runs live each weekday morning; this keeps its promises on every commit."""
import json;
import from datetime { datetime, timezone }
import from analysis.evaluation { evaluate, latest_evaluation, plain, record_evaluation }
import from analysis.final_report { render }
import from models.graph {
    CheckedBy,
    Coverage,
    Covers,
    Decided,
    Decision,
    Order,
    Placed,
    Portfolio,
    RiskCheck,
    RiskOutcome,
    Run,
    RunStatus,
    Sent,
    TradeAction,
    VoteRecord,
    Voted
}
import from tests.runs.action_exit_run { DAYS, ExitRun, exit_run }

glob DOWN_DAY: str = "2026-10-22";
glob BLACKOUT_DAY: str = "2026-10-23";
# The evening review after the last session.
glob EVENING: datetime = datetime(2026, 10, 23, 20, 30, tzinfo=timezone.utc);
def portfolio_of(found: ExitRun) -> Portfolio {
    assert found.portfolio is not None;
    return found.portfolio;
}

def runs_by_day(portfolio: Portfolio) -> dict[str, Run] {
    return {r.run_date: r for r in [portfolio -->[?:Run]]};
}

"""The decision a coverage reached, and the coverage itself, by ticker."""
def decided(run: Run) -> dict[str, tuple[Coverage, Decision]] {
    found: dict[str, tuple[Coverage, Decision]] = {};
    for c in [run ->:Covers:->[?:Coverage]] {
        for d in [c ->:Decided:->[?:Decision]] {
            found[c.ticker] = (c, d);
        }
    }
    return found;
}

"""Each test gets a fresh graph and the sessions take a minute, so one test runs the rehearsal
and each promise is its own check below."""
test "the rehearsed run keeps every promise of the launch guide" {
    found = exit_run(DOWN_DAY, {BLACKOUT_DAY: {"NVDA": 1}});
    assert found.passed();
    assert [d.run_status for d in found.days] == ["normal", "fallback", "normal"];
    orders_trace_back(found);
    refusal_sends_nothing(found);
    outage_stays_visible(found);
    report_reopens_the_same(found);
}

"""Every entry, add, and exit order hangs off one approved gate check, whose decision is the run's
for that ticker, with the panel's votes beside it. The order's ID names the same day and ticker."""
def orders_trace_back(found: ExitRun) {
    portfolio = portfolio_of(found);
    traced = 0;
    for (day, run) in runs_by_day(portfolio).items() {
        for (ticker, (cov, decision)) in decided(run).items() {
            for check in [decision ->:CheckedBy:->[?:RiskCheck]] {
                for order in [check ->:Placed:->[?:Order]] {
                    assert check.outcome != RiskOutcome.REJECTED and check.ticker == ticker;
                    assert order.client_order_id.startswith(f"{day}-{ticker}-");
                    assert order.qty <= check.approved_qty;
                    assert len([cov ->:Voted:->[?:VoteRecord]]) == 15;
                    traced += 1;
                }
            }
        }
    }
    # Every order that is not a protective stop came from a decision.
    sent = [o for o in [portfolio ->:Sent:->[?:Order]] if o.order_type != "stop"];
    assert traced == len(sent) == 5;
}

def refusal_sends_nothing(found: ExitRun) {
    portfolio = portfolio_of(found);
    run = runs_by_day(portfolio)[BLACKOUT_DAY];
    (_, decision) = decided(run)["NVDA"];
    assert decision.action == TradeAction.BUY;
    checks = [decision ->:CheckedBy:->[?:RiskCheck]];
    assert len(checks) == 1 and checks[0].outcome == RiskOutcome.REJECTED and checks[0].approved_qty == 0;
    assert [r.rule for r in checks[0].rules if not r.passed] == ["earnings blackout"];
    assert [checks[0] ->:Placed:->[?:Order]] == [];
    assert not any(o.client_order_id.startswith(f"{BLACKOUT_DAY}-NVDA") for o in [portfolio ->:Sent:->[?:Order]]);
    assert "refused: NVDA buy 38: earnings blackout" in run.execution_note;
}

"""A day the models are down is a fallback that says why, sends no order of its own, and still
lets the broker's stops protect what is held."""
def outage_stays_visible(found: ExitRun) {
    portfolio = portfolio_of(found);
    run = runs_by_day(portfolio)[DOWN_DAY];
    assert run.status == RunStatus.FALLBACK;
    assert run.summary.startswith("Models unavailable: no specialist answered for any of the 3 tickers (");
    assert {t: d.action for (t, (_, d)) in decided(run).items()} == {"AAPL": TradeAction.HOLD, "MSFT": TradeAction.HOLD, "NVDA": TradeAction.HOLD};
    assert all(len([c ->:Voted:->[?:VoteRecord]]) == 0 for (c, _) in decided(run).values());
    assert not any(o.client_order_id.startswith(f"{DOWN_DAY}-") for o in [portfolio ->:Sent:->[?:Order]]);
    thursday = [d for d in found.days if d.day == DOWN_DAY][0];
    assert "11:00 fill: NVDA: closed @ 191.00 (stop)" in thursday.log and thursday.clean();
}

"""The evening review stores one evaluation named by its snapshot ID. The Results page reads it
through get_evaluation, and the report is built from that same answer, so both show one ID. Built
twice, the report is the same; evaluated again from the same record, the ID is the same."""
def report_reopens_the_same(found: ExitRun) {
    portfolio = portfolio_of(found);
    record_evaluation(portfolio, evaluate(portfolio, DAYS, EVENING));
    stored = latest_evaluation(portfolio);
    assert stored is not None and len(stored.snapshot) == 8;
    assert stored.reliability.incomplete == [f"{DOWN_DAY}: no specialist answered"];
    assert stored.reliability.complete == 2 and stored.sessions == 3;
    # What get_evaluation sends, as the report's fetch saves it.
    answer = {"evaluation": json.loads(json.dumps(plain(stored))), "performance": None};
    (first, figures) = render(answer, None, None);
    assert render(json.loads(json.dumps(answer)), None, None) == (first, figures);
    assert f"(snapshot `{stored.snapshot}`" in first and "## Forward test: live paper trading" in first;
    # Three sessions are too few for a verdict, and the report says so with the count.
    matched = stored.comparisons[0].sessions;
    assert 0 < matched < 5 and f"not enough data ({matched} of 5 matched sessions)" in first;
    again = evaluate(portfolio, DAYS, EVENING);
    record_evaluation(portfolio, again);
    reopened = latest_evaluation(portfolio);
    assert reopened is not None and reopened.snapshot == stored.snapshot;
}

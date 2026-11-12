"""The forward test's evaluation (analysis/evaluation.jac): its statistics, its comparisons with
the baselines, and the component metrics read from a stored portfolio. No network."""
import math;
import from datetime { datetime, timezone }
import from action.fixtures { Call, finished_run, team }
import from analysis.evaluation {
    arbiter_result,
    block_resample,
    calibration,
    compare,
    daily_returns,
    evaluate,
    interval,
    latest_evaluation,
    max_drawdown,
    mean_estimate,
    record_evaluation,
    reliability,
    sharpe,
    snapshot_of,
    wilson
}
import from models.evaluation { MIN_VOTES }
import from models.agents { Specialist, Stance, Vote }
import from models.graph {
    Baseline,
    BaselineKind,
    Benchmarks,
    Coverage,
    CoverageReason,
    Covers,
    DailyMark,
    Evaluated,
    EvaluationRecord,
    Decided,
    Decision,
    Marked,
    Run,
    RunStatus,
    SimMarked,
    TradeAction,
    VoteRecord,
    Voted
}
import random;

glob NOW: datetime = datetime(2026, 11, 20, 21, 30, tzinfo=timezone.utc);

def mark(day: str, equity: float, bypasses: list[str] | None = None) -> DailyMark {
    return DailyMark(day=day, equity=equity, cash=equity, positions_value=0.0, peak_equity=equity, marked_at=f"{day}T21:30:00+00:00", bypasses=bypasses or []);
}

def scored_vote(specialist: Specialist, stance: Stance, confidence: float, excess: float | None) -> VoteRecord {
    return VoteRecord(ticker="AAA", specialist=specialist, sample=0, model="m", body=Vote(stance=stance, confidence=confidence, horizon_days=10, rationale="r", cited_evidence=[1]), excess_return=excess, scored_at="2026-11-20T21:30:00+00:00" if excess is not None else "");
}

test "returns compound from the starting cash, and Sharpe and drawdown follow their definitions" {
    returns = daily_returns([101.0, 99.99, 102.0], 100.0);
    assert [round(r, 6) for r in returns] == [0.01, -0.01, round(102.0 / 99.99 - 1.0, 6)];
    assert sharpe([0.01]) is None and sharpe([0.01, 0.01]) is None;
    expected = (0.01 + 0.03) / 2 / math.sqrt(((0.01 - 0.02) ** 2 + (0.03 - 0.02) ** 2) / 1) * math.sqrt(252);
    assert abs(sharpe([0.01, 0.03]) - expected) < 1e-9;
    assert abs(max_drawdown([110.0, 99.0, 120.0, 108.0], 100.0) - 0.1) < 1e-12;
    assert max_drawdown([100.0, 101.0], 100.0) == 0.0;
}

test "block resamples keep whole blocks and the length, and the same seed gives the same interval" {
    rng = random.Random(1);
    picked = block_resample(12, 5, rng);
    assert len(picked) == 12 and all(0 <= i < 12 for i in picked);
    # Every block but the last, which may be cut, is a run of consecutive indices.
    assert picked[1] == picked[0] + 1 and picked[4] == picked[0] + 4;
    values = [0.01 * i for i in range(20)];
    first = mean_estimate(values, 5);
    (lo, mid, hi) = (first.lo, first.value, first.hi);
    assert lo is not None and mid is not None and hi is not None and lo < mid < hi;
    assert mean_estimate(values, 5).lo == first.lo;
    assert mean_estimate([0.1, 0.2]).lo is None and mean_estimate([0.1, 0.2]).value is not None;
    assert interval(4, lambda (idx: list[int]) { 1.0; }) is None;
}

test "the Wilson interval holds the rate and stays inside 0 and 1" {
    found = wilson(9, 10);
    assert found.value == 0.9 and found.lo < 0.9 < found.hi <= 1.0;
    assert wilson(0, 5).lo == 0.0 and wilson(0, 0).value is None;
}

test "a comparison pairs the days both portfolios marked, and an interval clear of zero decides the verdict" {
    days = [f"2026-11-{d:02d}" for d in range(2, 22)];
    ours = [mark(d, 100000.0 * (1.004 ** (i + 1))) for (i, d) in enumerate(days)];
    flat = [mark(d, 100000.0 * (1.0 + 0.001 * ((-1) ** i))) for (i, d) in enumerate(days[:-2])];
    found = compare("spy", ours, 100000.0, flat, 100000.0);
    assert found.sessions == 18 and found.excess_return.n == 18;
    assert abs(found.excess_return.value - (1.004 ** 18 - 1.0 - (flat[-1].equity / 100000.0 - 1.0))) < 1e-9;
    assert found.verdict == "ahead" and found.excess_return.lo > 0;
    assert found.label == "SPY buy-and-hold";
    assert compare("spy", ours, 100000.0, [], 100000.0).sessions == 0;
}

test "calibration compares the mean confidence with the hit rate, by bin, and ignores HOLD and unscored votes" {
    votes = [
        scored_vote(Specialist.TECHNICAL, Stance.BUY, 0.8, 0.02),
        scored_vote(Specialist.TECHNICAL, Stance.BUY, 0.8, -0.01),
        scored_vote(Specialist.TECHNICAL, Stance.SELL, 0.6, -0.03),
        scored_vote(Specialist.TECHNICAL, Stance.HOLD, 0.9, 0.05),
        scored_vote(Specialist.TECHNICAL, Stance.BUY, 0.7, None)
    ];
    found = calibration("technical", votes);
    assert found.votes == 3 and abs(found.hit_rate.value - 2 / 3) < 1e-12;
    assert abs(found.confidence - (0.8 + 0.8 + 0.6) / 3) < 1e-12;
    assert abs(found.gap - (2 / 3 - 2.2 / 3)) < 1e-12;
    # Three votes are too few to call a specialist calibrated either way.
    assert found.within_target is None;
    by_low = {b.low: b for b in found.bins};
    assert by_low[0.6].votes == 1 and by_low[0.6].hit_rate == 1.0;
    assert by_low[0.8].votes == 2 and by_low[0.8].hit_rate == 0.5;
    assert by_low[0.0].votes == 0 and by_low[0.0].hit_rate is None;
}

test "the Arbiter helped when the buys it blocked lagged SPY; confirmed buys are reported beside them" {
    decisions = [
        Decision(ticker=f"B{i}", action=TradeAction.NO_ACTION, conviction=0.0, arbiter_verdict="DOWNGRADE", excess_return=-0.02 - 0.001 * i)
        for i in range(6)
    ] + [
        Decision(ticker="C", action=TradeAction.BUY, conviction=0.5, arbiter_verdict="CONFIRM", excess_return=0.01),
        Decision(ticker="H", action=TradeAction.HOLD, conviction=0.0, arbiter_verdict="CONFIRM", excess_return=0.5),
        Decision(ticker="U", action=TradeAction.NO_ACTION, conviction=0.0, arbiter_verdict="unavailable", excess_return=0.5),
        Decision(ticker="N", action=TradeAction.NO_ACTION, conviction=0.0, arbiter_verdict="DOWNGRADE")
    ];
    found = arbiter_result(decisions);
    assert found.blocked == 6 and found.confirmed == 1;
    assert found.blocked_excess.hi < 0 and found.verdict == "helped";
    assert abs(found.confirmed_excess.value - 0.01) < 1e-12;
    assert arbiter_result([]).verdict == "no data";
}

test "a session with no run is missed, and a failed run or an undecided ticker is incomplete" {
    portfolio = team();
    ok = finished_run(portfolio, "2026-11-02", [Call(ticker="AAA", action=TradeAction.HOLD)]);
    failed = finished_run(portfolio, "2026-11-03", [], status=RunStatus.FAILED);
    partial = finished_run(portfolio, "2026-11-05", [Call(ticker="AAA", action=TradeAction.HOLD)]);
    partial +>:Covers():+> Coverage(ticker="BBB", sector="Energy", reason=CoverageReason.SCREEN);
    found = reliability(["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"], {r.run_date: r for r in [ok, failed, partial]});
    assert found.sessions == 4 and found.complete == 1 and found.share == 0.25;
    assert found.missed == ["2026-11-04"];
    assert found.incomplete == ["2026-11-03: failed", "2026-11-05: 1 of 2 tickers without a decision"];
}

test "from MIN_VOTES scored votes, calibration says whether the hit rate is within 10 points" {
    votes = [scored_vote(Specialist.TECHNICAL, Stance.BUY, 0.6, 0.01 if i % 5 else -0.01) for i in range(MIN_VOTES)];
    found = calibration("technical", votes);
    assert found.votes == MIN_VOTES and abs(found.hit_rate.value - 0.8) < 1e-12;
    assert found.within_target == False;
    assert calibration("technical", votes[:-1]).within_target is None;
}

test "an evaluation of a stored portfolio covers its sessions, baselines, screen, panel, and operations, and is stored once" {
    portfolio = team();
    days = ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-09"];
    for (i, d) in enumerate(days) {
        run = finished_run(portfolio, d, [Call(ticker="AAA", action=TradeAction.HOLD)]);
        run.model_requests = 400 + i;
        run.screen_picks_excess = 0.01;
        run.screen_rest_excess = 0.0 if i % 2 else 0.02;
        cov = [run ->:Covers:->[?:Coverage]][0];
        cov +>:Voted():+> scored_vote(Specialist.NEWS, Stance.BUY, 0.7, 0.01 if i % 3 else -0.01);
        portfolio +>:Marked():+> mark(d, 100000.0 + 100.0 * i, ["x"] if i == 5 else []);
    }
    spy = Baseline(kind=BaselineKind.SPY, starting_cash=100000.0, start_day="2026-11-02", cash=0.0);
    portfolio +>:Benchmarks():+> spy;
    for (i, d) in enumerate(days[:-1]) {
        spy +>:SimMarked():+> mark(d, 100000.0 - 50.0 * i);
    }
    sessions = days + ["2026-11-10"];
    found = evaluate(portfolio, sessions, NOW);
    assert found.start_day == "2026-11-02" and found.last_day == "2026-11-09" and found.sessions == 6;
    assert [s.key for s in found.series] == ["team", "spy"] and found.series[0].sessions == 6;
    assert len(found.comparisons) == 1 and found.comparisons[0].sessions == 5 and found.comparisons[0].excess_return.value > 0;
    assert found.screen.runs == 6 and found.screen.positive_runs == 3 and abs(found.screen.spread.value if found.screen.spread.value is not None else 1.0) < 1e-12;
    assert [s.specialist for s in found.specialists] == ["news"] and found.specialists[0].votes == 6;
    assert found.reliability.complete == 6 and found.reliability.share == 1.0;
    assert found.operations.bypasses == 1 and found.operations.requests_max_run == 405;
    assert found.operations.latency_median_minutes == 90.0 and found.operations.under_two_hours == 6;
    record_evaluation(portfolio, found);
    again = evaluate(portfolio, sessions, NOW);
    record_evaluation(portfolio, again);
    stored = latest_evaluation(portfolio);
    assert stored is not None and stored.as_of == again.as_of;
    assert len(stored.snapshot) == 8 and stored.snapshot == snapshot_of(stored);
    assert latest_evaluation(team()) is None;
}

"""The snapshot ID is what the Results page and the final report both print, so a reader can see
they describe the same stored evaluation."""
test "a snapshot ID follows the evaluation's figures and nothing else" {
    portfolio = team();
    run = finished_run(portfolio, "2026-11-02", [Call(ticker="AAA", action=TradeAction.HOLD)]);
    portfolio +>:Marked():+> mark("2026-11-02", 100000.0);
    first = evaluate(portfolio, ["2026-11-02"], NOW);
    same = evaluate(portfolio, ["2026-11-02"], NOW);
    assert snapshot_of(first) == snapshot_of(same);
    first.snapshot = "ffffffff";
    assert snapshot_of(first) == snapshot_of(same);
    later = evaluate(portfolio, ["2026-11-02"], datetime(2026, 11, 21, 21, 30, tzinfo=timezone.utc));
    assert snapshot_of(later) != snapshot_of(same);
    assert run is not None;
}

test "an evaluation stored before snapshot IDs gets one on read, without the read changing it" {
    portfolio = team();
    portfolio +>:Marked():+> mark("2026-11-02", 100000.0);
    record_evaluation(portfolio, evaluate(portfolio, ["2026-11-02"], NOW));
    record = [portfolio ->:Evaluated:->[?:EvaluationRecord]][0];
    named = record.body.snapshot;
    record.body.snapshot = "";
    found = latest_evaluation(portfolio);
    assert found is not None and found.snapshot == named;
    assert record.body.snapshot == "";
}

test "a portfolio with no runs has an empty evaluation" {
    found = evaluate(team(), ["2026-11-02"], NOW);
    assert not found.demo;
    assert found.start_day == "" and found.sessions == 0 and found.series == [] and found.arbiter.verdict == "no data";
}

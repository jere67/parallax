"""The forward test's evaluation (TDD §13, metrics), computed from what the graph already holds:
the daily marks of the portfolio and its baselines, the scored votes and decisions, and each
run's scored screen (analysis/scoring.jac). It reads no prices and calls no model, so the evening
review can rebuild it every day (run/trading.jac) and store it for the Results page and the final
report (models/evaluation.jac).

Intervals are 95%:
- Comparisons with a baseline resample the paired daily returns in moving blocks of
  `BLOCK_SESSIONS` sessions, since returns cluster, and recompute the statistic on each resample.
- The screen's spread resamples runs in the same blocks, since neighboring runs' ten-session
  windows overlap.
- The Arbiter's trades resample one trade at a time.
- Hit rates use the Wilson interval.
Every resample uses the same seed, so an evaluation of the same data always gives the same
intervals. A stored evaluation carries a snapshot ID made from its content, which the Results page
and the final report both show.
"""
import copy;
import hashlib;
import json;
import math;
import random;
import statistics;
import from datetime { datetime }
import from action.baselines { baselines_of, sim_marks }
import from action.reconcile { marks_of }
import from agents.models { FREE_REQUESTS_PER_DAY }
import from analysis.scoring { hit }
import from models.evaluation {
    ArbiterResult,
    CalibrationBin,
    Comparison,
    Estimate,
    Evaluation,
    MIN_SESSIONS,
    MIN_VOTES,
    Operations,
    Reliability,
    ScreenResult,
    SeriesResult,
    SpecialistCalibration
}
import from models.graph {
    BaselineKind,
    Counted,
    Coverage,
    Covers,
    DailyMark,
    Decided,
    Decision,
    EvaluationRecord,
    Evaluated,
    Portfolio,
    Ran,
    RequestCount,
    Run,
    RunStatus,
    TradeAction,
    VoteRecord,
    Voted
}
import from run.public { public }

glob TRADING_DAYS: int = 252;
glob BLOCK_SESSIONS: int = 5;
glob RESAMPLES: int = 2000;
glob SEED: int = 449;
glob CALIBRATION_TARGET: float = 0.10;
glob LATENCY_TARGET_MINUTES: float = 120.0;
glob CALIBRATION_BINS: list[tuple[float, float]] = [(0.0, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 1.0)];
glob SERIES_LABELS: dict[str, str] = {"team": "Your agent", "equal_weight": "Equal-weight shortlist", "spy": "SPY buy-and-hold"};
glob COMPLETE: tuple[RunStatus, RunStatus] = (RunStatus.NORMAL, RunStatus.FALLBACK);

# --- Statistics ---------------------------------------------------------------------------

"""Daily returns of `equities`, the first measured from `start`."""
def daily_returns(equities: list[float], start: float) -> list[float] {
    found: list[float] = [];
    before = start;
    for e in equities {
        if before > 0 {
            found.append(e / before - 1.0);
        }
        before = e;
    }
    return found;
}

def compounded(returns: list[float]) -> float {
    total = 1.0;
    for r in returns {
        total *= 1.0 + r;
    }
    return total - 1.0;
}

"""Mean daily return over its sample deviation, annualized by the square root of 252, with a
risk-free rate of zero; None with fewer than two returns or none that differ."""
def sharpe(returns: list[float]) -> float | None {
    if len(returns) < 2 {
        return None;
    }
    spread = statistics.stdev(returns);
    return statistics.fmean(returns) / spread * math.sqrt(TRADING_DAYS) if spread > 0 else None;
}

"""The largest fall from a peak, as a fraction of the peak, counting `start` as the first peak."""
def max_drawdown(equities: list[float], start: float) -> float {
    peak = start;
    worst = 0.0;
    for e in equities {
        peak = max(peak, e);
        if peak > 0 {
            worst = max(worst, 1.0 - e / peak);
        }
    }
    return worst;
}

"""Indices 0..n-1 resampled in moving blocks of `block`: random block starts, each block taken
whole, until there are n."""
def block_resample(n: int, block: int, rng: random.Random) -> list[int] {
    size = max(1, min(block, n));
    found: list[int] = [];
    while len(found) < n {
        first = rng.randrange(0, n - size + 1);
        found.extend(range(first, first + size));
    }
    return found[:n];
}

"""The 2.5th and 97.5th percentiles of `statistic` over moving-block resamples of n
observations, or None when there are fewer than MIN_SESSIONS observations or no resample gives
a value."""
def interval(n: int, statistic: Callable[[list[int]], float | None], block: int = BLOCK_SESSIONS) -> tuple[float, float] | None {
    if n < MIN_SESSIONS {
        return None;
    }
    rng = random.Random(SEED);
    values: list[float] = [];
    for _ in range(RESAMPLES) {
        value = statistic(block_resample(n, block, rng));
        if value is not None {
            values.append(value);
        }
    }
    if not values {
        return None;
    }
    values.sort();
    return (percentile(values, 0.025), percentile(values, 0.975));
}

"""The `q` quantile of sorted `values`, interpolating between neighbors."""
def percentile(values: list[float], q: float) -> float {
    at = q * (len(values) - 1);
    low = int(math.floor(at));
    high = min(low + 1, len(values) - 1);
    return values[low] + (values[high] - values[low]) * (at - low);
}

"""The mean of `values` with a resampled interval (`block` 1 resamples one at a time)."""
def mean_estimate(values: list[float], block: int = 1) -> Estimate {
    if not values {
        return Estimate();
    }
    def mean_of(idx: list[int]) -> float | None {
        return statistics.fmean(values[i] for i in idx);
    }
    found = interval(len(values), mean_of, block);
    return Estimate(value=statistics.fmean(values), lo=found[0] if found else None, hi=found[1] if found else None, n=len(values));
}

"""The Wilson 95% interval of `hits` out of `n`, with the rate itself."""
def wilson(hits: int, n: int) -> Estimate {
    if n == 0 {
        return Estimate();
    }
    z = 1.959964;
    p = hits / n;
    center = (p + z * z / (2 * n)) / (1 + z * z / n);
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n);
    return Estimate(value=p, lo=max(0.0, center - half), hi=min(1.0, center + half), n=n);
}

"""'ahead' or 'behind' when the estimate's interval excludes zero, else 'unclear'."""
def side_of(found: Estimate, above: str = "ahead", below: str = "behind") -> str {
    if found.lo is not None and found.lo > 0 {
        return above;
    }
    if found.hi is not None and found.hi < 0 {
        return below;
    }
    return "unclear";
}

# --- Performance --------------------------------------------------------------------------

"""Marks in day order, from `start_day` on."""
def marks_from(found: dict[str, DailyMark], start_day: str) -> list[DailyMark] {
    return [found[d] for d in sorted(found) if d >= start_day];
}

def series_result(key: str, marks: list[DailyMark], starting_cash: float) -> SeriesResult {
    equities = [m.equity for m in marks];
    returns = daily_returns(equities, starting_cash);
    return SeriesResult(
        key=key,
        label=SERIES_LABELS.get(key, key),
        sessions=len(marks),
        total_return=equities[-1] / starting_cash - 1.0 if equities and starting_cash > 0 else None,
        sharpe=sharpe(returns),
        max_drawdown=max_drawdown(equities, starting_cash) if equities else None
    );
}

"""The system against a baseline over the days both marked, each measured from its own starting
cash: the difference in total return and in Sharpe ratio, with block-bootstrap intervals over the
paired daily returns."""
def compare(key: str, team: list[DailyMark], team_cash: float, base: list[DailyMark], base_cash: float) -> Comparison {
    theirs = {m.day: m.equity for m in base};
    days = [m.day for m in team if m.day in theirs];
    found = Comparison(baseline=key, label=SERIES_LABELS.get(key, key), sessions=len(days), excess_return=Estimate(), sharpe_difference=Estimate());
    if not days {
        return found;
    }
    ours = {m.day: m.equity for m in team};
    mine = daily_returns([ours[d] for d in days], team_cash);
    other = daily_returns([theirs[d] for d in days], base_cash);
    n = min(len(mine), len(other));
    (mine, other) = (mine[:n], other[:n]);
    def excess(idx: list[int]) -> float | None {
        return compounded([mine[i] for i in idx]) - compounded([other[i] for i in idx]);
    }
    def gap(idx: list[int]) -> float | None {
        (a, b) = (sharpe([mine[i] for i in idx]), sharpe([other[i] for i in idx]));
        return a - b if a is not None and b is not None else None;
    }
    whole = list(range(n));
    spread = interval(n, excess);
    found.excess_return = Estimate(value=excess(whole), lo=spread[0] if spread else None, hi=spread[1] if spread else None, n=n);
    difference = gap(whole);
    if difference is not None {
        spread = interval(n, gap);
        found.sharpe_difference = Estimate(value=difference, lo=spread[0] if spread else None, hi=spread[1] if spread else None, n=n);
    }
    found.verdict = side_of(found.excess_return);
    return found;
}

# --- Components ---------------------------------------------------------------------------

def screen_result(runs: list[Run]) -> ScreenResult {
    scored = [r for r in sorted(runs, key=lambda (r: Run) { r.run_date; }) if r.screen_picks_excess is not None and r.screen_rest_excess is not None];
    if not scored {
        return ScreenResult(spread=Estimate());
    }
    picks = [float(r.screen_picks_excess or 0.0) for r in scored];
    rest = [float(r.screen_rest_excess or 0.0) for r in scored];
    spreads = [a - b for (a, b) in zip(picks, rest)];
    return ScreenResult(
        runs=len(scored),
        picks_excess=statistics.fmean(picks),
        rest_excess=statistics.fmean(rest),
        spread=mean_estimate(spreads, BLOCK_SESSIONS),
        positive_runs=len([s for s in spreads if s > 0])
    );
}

def calibration(specialist: str, votes: list[VoteRecord]) -> SpecialistCalibration {
    scored = [v for v in votes if hit(v) is not None];
    found = SpecialistCalibration(specialist=specialist, votes=len(scored), hit_rate=wilson(len([v for v in scored if hit(v)]), len(scored)), bins=[]);
    if not scored {
        return found;
    }
    found.confidence = statistics.fmean(v.body.confidence for v in scored);
    found.gap = found.hit_rate.value - found.confidence if found.hit_rate.value is not None else None;
    # Too few votes say nothing about calibration either way.
    found.within_target = abs(found.gap) <= CALIBRATION_TARGET if found.gap is not None and len(scored) >= MIN_VOTES else None;
    for (i, (low, high)) in enumerate(CALIBRATION_BINS) {
        last = i == len(CALIBRATION_BINS) - 1;
        inside = [v for v in scored if v.body.confidence >= low and (v.body.confidence <= high if last else v.body.confidence < high)];
        found.bins.append(CalibrationBin(
            low=low,
            high=high,
            votes=len(inside),
            confidence=statistics.fmean(v.body.confidence for v in inside) if inside else None,
            hit_rate=len([v for v in inside if hit(v)]) / len(inside) if inside else None
        ));
    }
    return found;
}

def arbiter_result(decisions: list[Decision]) -> ArbiterResult {
    blocked = [d.excess_return for d in decisions if d.arbiter_verdict == "DOWNGRADE" and d.excess_return is not None];
    confirmed = [d.excess_return for d in decisions if d.arbiter_verdict == "CONFIRM" and d.action in (TradeAction.BUY, TradeAction.ADD) and d.excess_return is not None];
    found = ArbiterResult(blocked=len(blocked), blocked_excess=mean_estimate(blocked), confirmed=len(confirmed), confirmed_excess=mean_estimate(confirmed));
    found.verdict = side_of(found.blocked_excess, above="hurt", below="helped") if blocked else "no data";
    return found;
}

"""Each trading session from the start through the last day: a run that finished normally or in
fallback with a decision for every covered ticker, and a vote from at least one specialist, is
complete. Holds that no specialist voted on, as when every model was down, are not."""
def reliability(sessions: list[str], runs: dict[str, Run]) -> Reliability {
    found = Reliability(sessions=len(sessions), missed=[], incomplete=[]);
    for day in sessions {
        run = runs.get(day);
        if run is None {
            found.missed.append(day);
            continue;
        }
        coverages = [run ->:Covers:->[?:Coverage]];
        undecided = len([c for c in coverages if not [c ->:Decided:->[?:Decision]]]);
        if run.status not in COMPLETE {
            found.incomplete.append(f"{day}: {run.status.value}");
        } elif undecided {
            found.incomplete.append(f"{day}: {undecided} of {len(coverages)} tickers without a decision");
        } elif coverages and not any([c ->:Voted:->[?:VoteRecord]] for c in coverages) {
            found.incomplete.append(f"{day}: no specialist answered");
        } else {
            found.complete += 1;
        }
    }
    found.share = found.complete / len(sessions) if sessions else None;
    return found;
}

def minutes_between(start: str, end: str) -> float | None {
    try {
        return (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds() / 60.0;
    } except ValueError {
        return None;
    }
}

"""Risk-gate bypasses on the portfolio's marks, the runs' own time from preflight to their
decisions (orders wait for 9:45 by design, so time to orders measures the clock, not the run),
and free-model requests per run and per UTC day."""
def operations(portfolio: Portfolio, marks: list[DailyMark], runs: list[Run], since: str) -> Operations {
    finished = [r for r in runs if r.finished_at and r.status in COMPLETE];
    minutes = sorted(x for x in [minutes_between(r.started_at, r.finished_at) for r in finished] if x is not None);
    requests = [r.model_requests for r in runs if r.status in COMPLETE];
    counts = [c.used for c in [portfolio ->:Counted:->[?:RequestCount]] if c.day >= since];
    return Operations(
        bypasses=sum(len(m.bypasses) for m in marks),
        executed_runs=len([r for r in runs if r.executed_at]),
        latency_median_minutes=statistics.median(minutes) if minutes else None,
        latency_max_minutes=minutes[-1] if minutes else None,
        under_two_hours=len([m for m in minutes if m < LATENCY_TARGET_MINUTES]),
        requests_per_run=statistics.fmean(requests) if requests else None,
        requests_max_run=max(requests) if requests else 0,
        peak_daily_requests=max(counts) if counts else 0,
        daily_cap=FREE_REQUESTS_PER_DAY
    );
}

# --- The evaluation -----------------------------------------------------------------------

"""The forward-test start: the baselines' start day, or the first run's day for a portfolio
without baselines, or "" when there is neither."""
def start_of(portfolio: Portfolio, runs: list[Run]) -> str {
    starts = [b.start_day for b in baselines_of(portfolio).values()];
    if starts {
        return min(starts);
    }
    return min(r.run_date for r in runs) if runs else "";
}

"""The evaluation of `portfolio` as of `now`. `sessions` are the market's trading sessions,
in order, through at least the last day to count; reliability counts those from the start
through `last_day` (the latest mark, or the latest run without marks)."""
def evaluate(portfolio: Portfolio, sessions: list[str], now: datetime) -> Evaluation {
    runs = sorted([portfolio ->:Ran:->[?:Run]], key=lambda (r: Run) { r.run_date; });
    start = start_of(portfolio, runs);
    found = Evaluation(as_of=now.isoformat(), start_day=start, series=[], comparisons=[], specialists=[], notes=[], demo=portfolio.demo);
    if not start {
        found.screen = ScreenResult(spread=Estimate());
        found.arbiter = ArbiterResult(blocked_excess=Estimate(), confirmed_excess=Estimate(), verdict="no data");
        found.reliability = Reliability(missed=[], incomplete=[]);
        found.operations = Operations(daily_cap=FREE_REQUESTS_PER_DAY);
        return found;
    }
    team = marks_from(marks_of(portfolio), start);
    since = [r for r in runs if r.run_date >= start];
    found.last_day = team[-1].day if team else (since[-1].run_date if since else start);
    counted = [s for s in sessions if start <= s <= found.last_day];
    found.sessions = len(counted);

    found.series.append(series_result("team", team, portfolio.starting_cash));
    for kind in [BaselineKind.EQUAL_WEIGHT, BaselineKind.SPY] {
        b = baselines_of(portfolio).get(kind);
        if b is not None {
            theirs = marks_from(sim_marks(b), start);
            found.series.append(series_result(kind.value, theirs, b.starting_cash));
            found.comparisons.append(compare(kind.value, team, portfolio.starting_cash, theirs, b.starting_cash));
        }
    }

    found.screen = screen_result(runs);
    coverages = [c for r in runs for c in [r ->:Covers:->[?:Coverage]]];
    votes = [v for c in coverages for v in [c ->:Voted:->[?:VoteRecord]]];
    for specialist in sorted({v.specialist.value for v in votes}) {
        found.specialists.append(calibration(specialist, [v for v in votes if v.specialist.value == specialist]));
    }
    found.arbiter = arbiter_result([d for c in coverages for d in [c ->:Decided:->[?:Decision]]]);
    found.reliability = reliability(counted, {r.run_date: r for r in since});
    found.operations = operations(portfolio, team, since, start);
    if not team {
        found.notes.append("The portfolio has no closing marks yet, so there is no performance to compare.");
    }
    return found;
}

"""`v` as plain JSON values: an object as its fields, by name."""
def plain(v: object) -> object {
    if isinstance(v, (list, tuple)) {
        return [plain(x) for x in v];
    }
    if isinstance(v, dict) {
        return {str(k): plain(x) for (k, x) in v.items()};
    }
    if hasattr(v, "__dict__") {
        return {k: plain(x) for (k, x) in vars(v).items() if not k.startswith("_")};
    }
    return v;
}

"""A short ID for `body`'s content: the first 8 hex digits of the SHA-256 of its fields as sorted
JSON, leaving out the ID itself. The same figures always give the same ID."""
def snapshot_of(body: Evaluation) -> str {
    content = {k: plain(v) for (k, v) in vars(body).items() if not k.startswith("_") and k != "snapshot"};
    return hashlib.sha256(json.dumps(content, sort_keys=True, `default=str).encode("utf-8")).hexdigest()[:8];
}

"""Store `body` as `portfolio`'s latest evaluation, replacing the one before, named by its
snapshot ID."""
def record_evaluation(portfolio: Portfolio, body: Evaluation) -> EvaluationRecord {
    body.snapshot = snapshot_of(body);
    for found in [portfolio ->:Evaluated:->[?:EvaluationRecord]] {
        found.as_of = body.as_of;
        found.body = body;
        return found;
    }
    return public(portfolio +>:Evaluated():+> EvaluationRecord(as_of=body.as_of, body=body));
}

"""`portfolio`'s latest stored evaluation, or None before the first evening review. One stored
before snapshot IDs gets its ID here, on a copy, so a read never writes."""
def latest_evaluation(portfolio: Portfolio) -> Evaluation | None {
    for found in [portfolio ->:Evaluated:->[?:EvaluationRecord]] {
        if found.body.snapshot {
            return found.body;
        }
        named = copy.copy(found.body);
        named.snapshot = snapshot_of(found.body);
        return named;
    }
    return None;
}

"""The forward test's evaluation (TDD §13, metrics), as the evening review computes it from the
graph (analysis/evaluation.jac) and the Results page and the final report read it.

These types are stored inside an EvaluationRecord node (models/graph.jac), so this module's path is
frozen once data is stored. Every figure that can be missing is None rather than 0, so a reader can
tell "no data yet" from "zero".
"""

# The fewest observations a figure is shown from. Below them the Results page, the Specialists page,
# and the final report say "not enough data" with how many there are of how many it needs, never a
# bare figure: a hit rate needs MIN_VOTES scored votes (a role's, or one confidence band's), and an
# interval over sessions or runs needs MIN_SESSIONS of them. dashboard/ui/evidence.jac mirrors these
# for the browser, and analysis/evaluation_tests.jac keeps the two equal.
glob MIN_VOTES: int = 20;
glob MIN_SESSIONS: int = 5;

"""A figure with its 95% interval. `lo` and `hi` are None when there is too little data for an
interval; `n` is how many observations it rests on."""
obj Estimate {
    has value: float | None = None,
        lo: float | None = None,
        hi: float | None = None,
        n: int = 0;
}

"""One portfolio over the forward test: the full system or a baseline."""
obj SeriesResult {
    has key: str,
        label: str;
    has sessions: int = 0,
        total_return: float | None = None,
        sharpe: float | None = None,
        max_drawdown: float | None = None;
}

"""The full system against one baseline over the sessions both marked. `excess_return` is the
system's total return minus the baseline's and `sharpe_difference` the gap in Sharpe ratios, each
with a moving-block bootstrap interval. `verdict` is "ahead" or "behind" when the excess return's
interval excludes zero, and "unclear" otherwise."""
obj Comparison {
    has baseline: str,
        label: str;
    has sessions: int = 0,
        excess_return: Estimate = Estimate(),
        sharpe_difference: Estimate = Estimate(),
        verdict: str = "unclear";
}

"""The screen's hit rate (TDD §5): each scored run's shortlisted names against the rest of the
S&P 500 over the next ten sessions, both as excess returns over SPY. `spread` is the picks' mean
minus the rest's, over runs, with a bootstrap interval across runs."""
obj ScreenResult {
    has runs: int = 0,
        picks_excess: float | None = None,
        rest_excess: float | None = None,
        spread: Estimate = Estimate(),
        positive_runs: int = 0;
}

"""Scored directional votes whose stated confidence falls in [low, high)."""
obj CalibrationBin {
    has low: float,
        high: float;
    has votes: int = 0,
        confidence: float | None = None,
        hit_rate: float | None = None;
}

"""One specialist's calibration: its mean stated confidence against its realized hit rate (with a
Wilson interval) over scored directional votes. `gap` is hit rate minus confidence; the target is
within 10 percentage points either way."""
obj SpecialistCalibration {
    has specialist: str;
    has votes: int = 0,
        confidence: float | None = None,
        hit_rate: Estimate = Estimate(),
        gap: float | None = None,
        within_target: bool | None = None,
        bins: list[CalibrationBin] = [];
}

"""What the Arbiter's reviews were worth: the ten-session excess return of the buys and adds it
downgraded, had they been taken, and of those it confirmed. Blocking helped when the blocked
trades' mean is negative."""
obj ArbiterResult {
    has blocked: int = 0,
        blocked_excess: Estimate = Estimate(),
        confirmed: int = 0,
        confirmed_excess: Estimate = Estimate(),
        verdict: str = "unclear";
}

"""Runs that produced a valid, complete decision set, out of the trading sessions since the start.
`missed` lists sessions with no run; `incomplete` lists runs that failed, skipped a trading day, or
left a covered ticker without a decision."""
obj Reliability {
    has sessions: int = 0,
        complete: int = 0,
        share: float | None = None,
        missed: list[str] = [],
        incomplete: list[str] = [];
}

"""Operating figures: risk-gate bypasses, run latency from the run's preflight to its decisions
(orders wait for 9:45 by design), and free-model requests per run and per day against the daily cap."""
obj Operations {
    has bypasses: int = 0,
        executed_runs: int = 0,
        latency_median_minutes: float | None = None,
        latency_max_minutes: float | None = None,
        under_two_hours: int = 0,
        requests_per_run: float | None = None,
        requests_max_run: int = 0,
        peak_daily_requests: int = 0,
        daily_cap: int = 0;
}

"""The whole evaluation as of `as_of` (an ISO timestamp), covering `sessions` sessions from
`start_day` to `last_day`. `snapshot` names this exact content (analysis/evaluation.jac,
`snapshot_of`), so the Results page and the final report can show they read the same one.
`demo` marks an evaluation of the simulated demo history, never of paper trading."""
obj Evaluation {
    has as_of: str;
    has start_day: str = "",
        last_day: str = "",
        sessions: int = 0,
        series: list[SeriesResult] = [],
        comparisons: list[Comparison] = [],
        screen: ScreenResult = ScreenResult(),
        specialists: list[SpecialistCalibration] = [],
        arbiter: ArbiterResult = ArbiterResult(),
        reliability: Reliability = Reliability(),
        operations: Operations = Operations(),
        notes: list[str] = [],
        snapshot: str = "",
        demo: bool = False;
}

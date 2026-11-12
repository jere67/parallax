"""The final report (analysis/final_report.jac): its formatting, its figures, and the report it
renders from the forward test's evaluation, the backtest, and the replay. No network."""
import re;
import tempfile;
import from pathlib { Path }
import from analysis.final_report {
    CalibrationRow,
    Line,
    calibration_chart,
    estimate,
    line_chart,
    pct,
    render,
    returns_from,
    ticks,
    write_report
}

def est(value: float | None, lo: float | None = None, hi: float | None = None, n: int = 0) -> dict[str, object] {
    return {"value": value, "lo": lo, "hi": hi, "n": n};
}

"""The shape of get_evaluation and get_performance as the server returns them."""
def forward -> dict[str, object] {
    days = ["2026-11-02", "2026-11-03", "2026-11-04"];
    def curve(key: str, equities: list[float]) -> dict[str, object] {
        return {"key": key, "label": key, "points": [{"day": d, "equity": e, "drawdown": 0.0} for (d, e) in zip(days, equities)]};
    }
    evaluation: dict[str, object] = {
        "as_of": "2026-11-04T21:30:00+00:00",
        "snapshot": "a1b2c3d4",
        "start_day": "2026-11-02",
        "last_day": "2026-11-04",
        "sessions": 3,
        "series": [
            {"key": "team", "label": "Team", "sessions": 3, "total_return": 0.012, "sharpe": 1.5, "max_drawdown": 0.004},
            {"key": "spy", "label": "SPY", "sessions": 3, "total_return": 0.004, "sharpe": 0.9, "max_drawdown": 0.01}
        ],
        "comparisons": [{"baseline": "spy", "label": "SPY buy-and-hold", "sessions": 3, "excess_return": est(0.008), "sharpe_difference": est(0.6), "verdict": "unclear"}],
        "screen": {"runs": 0, "picks_excess": None, "rest_excess": None, "spread": est(None), "positive_runs": 0},
        "specialists": [
            {"specialist": "technical", "votes": 12, "confidence": 0.7, "hit_rate": est(0.5, 0.25, 0.75, 12), "gap": -0.2, "within_target": False, "bins": []},
            {"specialist": "news", "votes": 0, "confidence": None, "hit_rate": est(None), "gap": None, "within_target": None, "bins": []}
        ],
        "arbiter": {"blocked": 2, "blocked_excess": est(-0.03), "confirmed": 1, "confirmed_excess": est(0.01), "verdict": "unclear"},
        "reliability": {"sessions": 3, "complete": 2, "share": 2 / 3, "missed": ["2026-11-03"], "incomplete": []},
        "operations": {"bypasses": 0, "executed_runs": 2, "latency_median_minutes": 41.0, "latency_max_minutes": 55.0, "under_two_hours": 2, "requests_per_run": 452.0, "requests_max_run": 470, "peak_daily_requests": 470, "daily_cap": 1000},
        "notes": []
    };
    return {
        "fetched_at": "2026-11-05T00:00:00+00:00",
        "evaluation": evaluation,
        "performance": {"started": True, "start_day": "2026-11-02", "starting_cash": 100000.0, "series": [curve("team", [100000.0, 100500.0, 101200.0]), curve("equal_weight", [100000.0, 99800.0, 100100.0]), curve("spy", [100000.0, 100200.0, 100400.0])]}
    };
}

def backtest(adopt: bool) -> dict[str, object] {
    def period(spread: float, sharpe: float) -> dict[str, object] {
        return {"days": 300, "spread": spread, "spread_ci": [spread - 0.004, spread + 0.004], "picks_mean": spread, "rest_mean": 0.0, "positive_days": 170, "portfolio": {"total_return": 0.5, "annual_return": 0.08, "sharpe": sharpe, "sharpe_ci_vs_spy": [-0.3, 0.4], "max_drawdown": 0.22}};
    }
    return {
        "generated_at": "2026-11-11T00:00:00+00:00",
        "train": ["2016-01-04", "2022-12-30"],
        "validation": ["2023-01-03", "2026-10-30"],
        "data": {"symbols": 712, "sessions": 2700, "decision_days": 540, "news": "every 5th session", "notes": ["Delisted names without bars are left out."]},
        "variants": [
            {"name": "V0", "kind": "screen", "config": {}, "train": period(0.002, 0.7), "validation": period(0.001, 0.8)},
            {"name": "V2", "kind": "screen", "config": {}, "train": period(0.004, 0.8), "validation": period(0.003, 0.9)}
        ],
        "spy": {"train": {"total_return": 0.9, "annual_return": 0.1, "sharpe": 0.7, "max_drawdown": 0.34}, "validation": {"total_return": 0.6, "annual_return": 0.13, "sharpe": 1.0, "max_drawdown": 0.1}},
        "current": {"screen": "V0", "stop_atr_multiple": 2.0},
        "chosen": {"screen": "V2" if adopt else "V0", "stop_atr_multiple": 2.0},
        "adopted": {"screen": adopt, "stop_atr_multiple": False},
        "reason": "V2 led on validation." if adopt else "Nothing led on validation.",
        "curves": {"validation": {"current": [["2023-01-03", 100.0], ["2026-10-30", 140.0]], "chosen": [["2023-01-03", 100.0], ["2026-10-30", 150.0]], "spy": [["2023-01-03", 100.0], ["2026-10-30", 160.0]]}}
    };
}

def replay -> dict[str, object] {
    return {
        "model": "free/model",
        "model_cutoff": "2025-06",
        "days": ["2025-09-02", "2025-09-15"],
        "tickers": ["AAA", "BBB"],
        "samples": 1,
        "requests_used": 900,
        "wall_minutes": 95.4,
        "audit": [{"source": "Finnhub key metrics", "treatment": "dropped", "detail": "current-only snapshot"}],
        "decisions": [{"day": "2025-09-02", "ticker": "AAA"}, {"day": "2025-09-15", "ticker": "BBB"}],
        "summary": {"pairs": 10, "complete": 9, "valid_votes": 44, "votes": 45, "directional_votes": 30, "hit_rate": 0.6, "hit_rate_ci": [0.42, 0.75], "buys": 3, "buy_mean_excess": 0.012, "late_evidence_count": 0, "notes": ["Ten days are too few to judge skill."]}
    };
}

test "returns and intervals read as signed percentages, and a missing interval says why" {
    assert pct(0.0123) == "+1.2%" and pct(0.5, False, 0) == "50%" and pct(None) == "n/a";
    assert estimate(est(0.01, -0.005, 0.02, 30)) == "+1.0% (95% interval -0.5% to +2.0%)";
    assert estimate(est(0.01)) == "+1.0% (too little data for an interval)";
    assert estimate(est(0.25, -0.1, 0.4), True, True) == "+0.25 (95% interval -0.10 to +0.40)";
    assert estimate(est(None)) == "n/a";
}

test "axis ticks are round, include zero's side, and cover the data" {
    found = ticks(-0.013, 0.042);
    assert found[0] <= -0.013 and found[-1] >= 0.042 and 0.0 in found;
    steps = {round(b - a, 9) for (a, b) in zip(found, found[1:])};
    assert len(steps) == 1 and 4 <= len(found) <= 8;
    # Rounding error in the data adds no empty tick: 160 / 100 - 1 is a hair over 0.6.
    assert ticks(0.0, 160.0 / 100.0 - 1.0)[-1] == 0.6;
    found_returns = returns_from([("a", 200.0), ("b", 210.0)]);
    assert [d for (d, _) in found_returns] == ["a", "b"] and found_returns[0][1] == 0.0 and abs(found_returns[1][1] - 0.05) < 1e-12;
    assert returns_from([]) == [];
}

test "a line chart draws every line with a legend and end labels that never overlap" {
    lines = [
        Line(key="a", label="Parallax", points=[("d1", 0.0), ("d2", 0.010), ("d3", 0.020)]),
        Line(key="b", label="SPY", points=[("d1", 0.0), ("d2", 0.011), ("d3", 0.0201)]),
        Line(key="c", label="Empty", points=[])
    ];
    svg = line_chart("Return <test>", lines);
    assert svg.startswith("<svg") and svg.rstrip().endswith("</svg>");
    assert "Return &lt;test&gt;" in svg and "Empty" not in svg;
    assert svg.count("<path class=\"s") == 2;
    ends = [float(y) for y in re.findall(r"<text class=\"ink\" x=\"[\d.]+\" y=\"([\d.]+)\">(?:Parallax|SPY) ", svg)];
    assert len(ends) == 2 and abs(ends[0] - ends[1]) >= 16;
    assert "prefers-color-scheme: dark" in svg;
    assert line_chart("none", [Line(key="x", label="X", points=[])]) == "";
}

test "the calibration chart puts each specialist's confidence and hit rate on one axis" {
    svg = calibration_chart([CalibrationRow(label="Technical", confidence=0.7, hit_rate=0.5, lo=0.25, hi=0.75, votes=12), CalibrationRow(label="Macro", confidence=0.6, hit_rate=0.6)]);
    assert svg.count("class=\"hollow\" cx") == 3 and svg.count("class=\"f1\" cx") == 3;
    assert "Technical" in svg and "Macro" in svg;
    assert calibration_chart([]) == "";
}

test "with every input, the report answers first and draws its figures" {
    (markdown, figures) = render(forward(), backtest(True), replay());
    assert sorted(figures) == ["backtest-validation.svg", "forward-test.svg"];
    assert "No specialist has 20 scored votes yet, so there is no calibration chart." in markdown;
    assert markdown.startswith("# Parallax final evaluation\n");
    assert "through the 2026-11-04 close (snapshot `a1b2c3d4`, stored 2026-11-04T21:30:00+00:00, the ID the Results page shows)" in markdown;
    assert "## Forward test: live paper trading" in markdown and "## Screen backtest: historical, no model" in markdown and "## LLM replay\n" in markdown;
    answer = markdown.split("## Answer first")[1].split("## Forward test")[0];
    assert "**Against SPY buy-and-hold**, there is not enough data (3 of 5 matched sessions) for a verdict." in answer;
    assert "| SPY buy-and-hold | 3 | not enough data (3 of 5 sessions) | n/a | not enough data |" in markdown;
    assert "chose screen `V2` with a 2.0 ATR stop; the screen was adopted." in answer;
    assert "60% of 30 directional votes right (95% interval 42% to 75%) on 2 past days." in answer;
    assert "| Parallax | +1.2% | 1.50 | 0.4% | 3 |" in markdown;
    assert "| Technical | 12 | 70% | not enough data (12 of 20 scored votes) | n/a | n/a |" in markdown;
    assert "| News | 0 | n/a | n/a | n/a | n/a |" in markdown;
    assert "2 of 3 trading sessions (67%)" in markdown and "Sessions without a run: 2026-11-03." in markdown;
    assert "median of 41 minutes" in markdown and "470 of the 1000 allowed" in markdown;
    assert "| `V2` | train | 300 | +0.40% | +0.00% to +0.80% | 0.80 | 22.0% |" in markdown;
    assert "| Finnhub key metrics | dropped | current-only snapshot |" in markdown;
    assert "**Arbiter.** There is not enough data (2 of 5 scored blocked buys) to say whether blocking them helped." in markdown;
    assert "- Delisted names without bars are left out." in markdown.split("## Limits")[1];
    assert "Run details:\n\n- Ten days are too few to judge skill." in markdown.split("## LLM replay")[1].split("## Limits")[0];
    assert "ran on 2 past days (2025-09-02 to 2025-09-15)" in markdown;
    assert "Chosen settings" in figures["backtest-validation.svg"];
    assert "—" not in markdown;
}

test "a replay still under way says how many of its days are done" {
    partial = replay();
    partial["decisions"] = [{"day": "2025-09-02", "ticker": "AAA"}];
    (markdown, _) = render(None, None, partial);
    assert "ran on 1 of 2 planned past days, so far (2025-09-02) for" in markdown;
    assert "**The LLM replay** is still under way (1 of 2 planned past days, so far), so it is not a benchmark;" in markdown;
    assert "## LLM replay (partial)" in markdown and "**Partial.** The replay is still under way" in markdown;
    answer = markdown.split("## ")[1];
    assert "60%" not in answer and "hit rate" not in answer.lower();
}

test "a day with no request count leaves out the busiest-day figure" {
    found = forward();
    record = found["evaluation"];
    assert isinstance(record, dict);
    operations = record["operations"];
    assert isinstance(operations, dict);
    operations["peak_daily_requests"] = 0;
    (markdown, _) = render(found, None, None);
    assert "averaged 452 per run (at most 470)." in markdown and "busiest day" not in markdown;
    assert "is missing.\n\n## LLM replay" in markdown;
}

test "a backtest that adopts nothing says so and draws only the current settings against SPY" {
    (markdown, figures) = render(None, backtest(False), None);
    assert "nothing beat the current settings on validation, so nothing was adopted." in markdown;
    assert "Chosen settings" not in figures["backtest-validation.svg"];
    assert "The forward test's evaluation is missing" in markdown;
    assert "Not available: `docs/evaluation/llm-replay.json` is missing." in markdown;
}

test "with no inputs, every section says what is missing and no figure is drawn" {
    (markdown, figures) = render(None, None, None);
    assert figures == {};
    assert "No evaluation is stored yet" in markdown and "`docs/evaluation/backtest.json` is missing" in markdown;
}

test "writing the report replaces figures it no longer draws" {
    with tempfile.TemporaryDirectory() as tmp {
        out = Path(tmp);
        (markdown, figures) = render(forward(), backtest(True), None);
        write_report(out, markdown, figures);
        assert (out / "figures" / "backtest-validation.svg").exists();
        (markdown, figures) = render(forward(), None, None);
        write_report(out, markdown, figures);
        assert not (out / "figures" / "backtest-validation.svg").exists();
        assert (out / "figures" / "forward-test.svg").exists() and (out / "report.md").read_text() == markdown;
    }
}

"""A figure with enough observations behind it shows, by the same rule the Results page uses."""
test "with enough sessions and votes, the report shows the figures and verdicts" {
    found = forward();
    evaluation = found["evaluation"];
    assert isinstance(evaluation, dict);
    evaluation["comparisons"] = [{"baseline": "spy", "label": "SPY buy-and-hold", "sessions": 8, "excess_return": est(0.008, -0.002, 0.018, 8), "sharpe_difference": est(0.6), "verdict": "unclear"}];
    evaluation["specialists"] = [{"specialist": "technical", "votes": 24, "confidence": 0.7, "hit_rate": est(0.5, 0.3, 0.7, 24), "gap": -0.2, "within_target": False, "bins": []}];
    (markdown, figures) = render(found, None, None);
    assert "**Against SPY buy-and-hold**, Parallax is not clear yet: +0.8% (95% interval -0.2% to +1.8%) over 8 matched sessions." in markdown;
    assert "| Technical | 24 | 70% | 50.0% (95% interval 30.0% to 70.0%) | -20% | no |" in markdown;
    assert "calibration.svg" in figures;
}

"""A finished replay with too few directional votes gives no hit rate."""
test "a finished replay with few directional votes says so instead of a hit rate" {
    few = replay();
    summary = few["summary"];
    assert isinstance(summary, dict);
    summary["directional_votes"] = 8;
    (markdown, _) = render(None, None, few);
    assert "with not enough data (8 of 20 directional votes) for a hit rate." in markdown;
    assert "| Directional votes right over ten sessions | not enough data (8 of 20 directional votes) |" in markdown;
}

"""The report reads no clock and fetches nothing, so the same files give the same report: reopening
it reproduces its numbers."""
test "rendering the same inputs twice gives the same report" {
    first = render(forward(), backtest(True), replay());
    assert render(forward(), backtest(True), replay()) == first;
}

"""An evaluation of the demo history says so wherever its figures appear."""
test "an evaluation of the demo history is labeled demo data, not paper trading" {
    found = forward();
    evaluation = found["evaluation"];
    assert isinstance(evaluation, dict);
    evaluation["demo"] = True;
    (markdown, _) = render(found, None, None);
    assert "## Forward test: simulated demo data" in markdown and "live paper trading" not in markdown;
    assert "- **Demo data.** The forward test here is the simulated demo history" in markdown.split("## ")[1];
}

"""The final report (TDD §13): the forward test's evaluation from a running server, the screen
backtest (docs/evaluation/backtest.json), and the LLM replay (docs/evaluation/llm-replay.json),
rendered as docs/evaluation/report.md with SVG figures in docs/evaluation/figures/.

It reads the server only through its API, signed in as the admin, whose agent is the team's, so
it is safe beside the live server:

    ADMIN_PASSWORD=... PARALLAX_FINAL_REPORT=1 jac run --no-takeover analysis/final_report.jac

`REPORT_URL` (default http://localhost:8100) names the server and `REPORT_USERNAME` (default
admin) the account. The fetched evaluation and equity curves are saved to
docs/evaluation/forward-test.json, and `REPORT_OFFLINE=1` rebuilds the report from the saved
files without a server. A missing input leaves its section saying so rather than failing.

The report is a pure function of those three files: it reads no clock, fetches no price, and calls
no model, so rebuilding it from the same files gives the same report, byte for byte. It prints the
evaluation's snapshot ID, the one the Results page shows for the same stored evaluation. Each
section names where its figures came from (live paper trading, a historical backtest, or an LLM
replay), a replay still under way is never quoted as a result, and a figure with too few
observations behind it says so, by the rule in models/evaluation.jac.
"""
import json;
import os;
import sys;
import math;
import httpx;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from models.evaluation { MIN_SESSIONS, MIN_VOTES }

glob RUN_ENV: str = "PARALLAX_FINAL_REPORT";
glob OUT_DIR: str = "docs/evaluation";
glob FORWARD_FILE: str = "forward-test.json";
glob BACKTEST_FILE: str = "backtest.json";
glob REPLAY_FILE: str = "llm-replay.json";
glob REPORT_FILE: str = "report.md";
glob REBUILD: str = "PARALLAX_FINAL_REPORT=1 jac run --no-takeover analysis/final_report.jac";

# --- Reading JSON -------------------------------------------------------------------------

def text(d: dict[str, object], key: str) -> str {
    v = d.get(key);
    return v if isinstance(v, str) else "";
}

def number(d: dict[str, object], key: str) -> float | None {
    v = d.get(key);
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None;
}

def whole(d: dict[str, object], key: str) -> int {
    v = d.get(key);
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0;
}

def flag(d: dict[str, object], key: str) -> bool | None {
    v = d.get(key);
    return v if isinstance(v, bool) else None;
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
    return [str(x) for x in v if isinstance(x, (str, int, float))] if isinstance(v, list) else [];
}

"""A [lo, hi] pair, or None when either end is missing."""
def pair(d: dict[str, object], key: str) -> tuple[float, float] | None {
    v = d.get(key);
    if isinstance(v, list) and len(v) == 2 and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v) {
        return (float(v[0]), float(v[1]));
    }
    return None;
}

"""A JSON file as a dict, or None when it is missing or not an object."""
def load(path: Path) -> dict[str, object] | None {
    if not path.exists() {
        return None;
    }
    raw = json.loads(path.read_text());
    return {str(k): v for (k, v) in raw.items()} if isinstance(raw, dict) else None;
}

# --- Formatting ---------------------------------------------------------------------------

def pct(v: float | None, signed: bool = True, digits: int = 1) -> str {
    if v is None {
        return "n/a";
    }
    return f"{v * 100:+.{digits}f}%" if signed else f"{v * 100:.{digits}f}%";
}

def ratio(v: float | None, signed: bool = False) -> str {
    if v is None {
        return "n/a";
    }
    return f"{v:+.2f}" if signed else f"{v:.2f}";
}

"""An Estimate (value, lo, hi, n) as "+1.2% (95% interval -0.5% to +2.9%)"."""
def estimate(e: dict[str, object], signed: bool = True, as_ratio: bool = False) -> str {
    def show(v: float | None) -> str {
        return ratio(v, signed) if as_ratio else pct(v, signed);
    }
    value = number(e, "value");
    (lo, hi) = (number(e, "lo"), number(e, "hi"));
    if value is None {
        return "n/a";
    }
    if lo is None or hi is None {
        return f"{show(value)} (too little data for an interval)";
    }
    return f"{show(value)} (95% interval {show(lo)} to {show(hi)})";
}

def span(lo_hi: tuple[float, float] | None, signed: bool = True, digits: int = 1) -> str {
    if lo_hi is None {
        return "n/a";
    }
    return f"{pct(lo_hi[0], signed, digits)} to {pct(lo_hi[1], signed, digits)}";
}

def verdict_words(verdict: str) -> str {
    return {"ahead": "ahead", "behind": "behind", "unclear": "not clear yet", "no data": "no data yet"}.get(verdict, verdict);
}

def arbiter_words(verdict: str) -> str {
    return {"helped": "so blocking them helped", "hurt": "so blocking them hurt"}.get(verdict, "so whether blocking them helped is not clear yet");
}

def table(head: list[str], rows: list[list[str]]) -> str {
    lines = ["| " + " | ".join(head) + " |", "|" + "|".join(["---"] * len(head)) + "|"];
    lines.extend(["| " + " | ".join(cell.replace("|", "\\|") for cell in row) + " |" for row in rows]);
    return "\n".join(lines);
}

def plural(n: int, word: str) -> str {
    return f"{n} {word}" if n == 1 else f"{n} {word}s";
}

"""What the report writes in place of a figure with too few observations behind it."""
def thin(have: int, need: int, unit: str) -> str {
    return f"not enough data ({have} of {need} {unit})";
}

# --- Figures ------------------------------------------------------------------------------

"""Light and dark steps of the reference categorical palette, in fixed order, with ink and
surface. Text wears ink, never a series color."""
glob STYLE: str = """<style>
.surface { fill: #fcfcfb; }
.ink { fill: #0b0b0b; }
.muted { fill: #52514e; }
.grid { stroke: #e4e3df; }
.axis { stroke: #a3a29c; }
.range { stroke: #a3a29c; }
.hollow { fill: #fcfcfb; stroke: #0b0b0b; }
.s1 { stroke: #2a78d6; } .f1 { fill: #2a78d6; }
.s2 { stroke: #eb6834; } .f2 { fill: #eb6834; }
.s3 { stroke: #1baf7a; } .f3 { fill: #1baf7a; }
text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; font-size: 12px; }
.title { font-size: 14px; font-weight: 600; }
@media (prefers-color-scheme: dark) {
  .surface { fill: #1a1a19; }
  .ink { fill: #f0efec; }
  .muted { fill: #c3c2b7; }
  .grid { stroke: #2e2e2c; }
  .axis { stroke: #6b6a65; }
  .range { stroke: #6b6a65; }
  .hollow { fill: #1a1a19; stroke: #f0efec; }
  .s1 { stroke: #3987e5; } .f1 { fill: #3987e5; }
  .s2 { stroke: #d95926; } .f2 { fill: #d95926; }
  .s3 { stroke: #199e70; } .f3 { fill: #199e70; }
}
</style>""";

"""One line of a line chart: a cumulative return (as a fraction) per day."""
obj Line {
    has key: str,
        label: str,
        points: list[tuple[str, float]];
}

def esc(s: str) -> str {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
}

"""An axis tick as a signed percentage, with no sign on zero and no decimals on whole numbers."""
def tick_label(v: float) -> str {
    if abs(v) < 1e-12 {
        return "0%";
    }
    return pct(v, True, 0 if abs(v * 100 - round(v * 100)) < 1e-9 else 1);
}

"""A round tick step that gives about five ticks over `extent`."""
def nice_step(extent: float) -> float {
    if extent <= 0 {
        return 0.01;
    }
    raw = extent / 5;
    power = 10 ** math.floor(math.log10(raw));
    for m in [1, 2, 2.5, 5, 10] {
        if m * power >= raw {
            return m * power;
        }
    }
    return 10 * power;
}

def ticks(lo: float, hi: float) -> list[float] {
    step = nice_step(hi - lo);
    first = math.floor(lo / step) * step;
    found: list[float] = [];
    v = first;
    while v <= hi + step * 1e-9 {
        found.append(round(v, 10));
        v += step;
    }
    if found and found[-1] < hi - step * 1e-9 {
        found.append(round(found[-1] + step, 10));
    }
    return found;
}

"""Equity curves as cumulative return since the first point, so portfolios of different sizes
share one axis."""
def returns_from(points: list[tuple[str, float]]) -> list[tuple[str, float]] {
    if not points or points[0][1] == 0 {
        return [];
    }
    base = points[0][1];
    return [(day, equity / base - 1.0) for (day, equity) in points];
}

"""Cumulative-return lines on one axis, with a legend above and each line labeled at its end.
Days are spaced evenly, as sessions rather than calendar time."""
def line_chart(title: str, lines: list[Line]) -> str {
    (width, height) = (760, 340);
    shown = [l for l in lines if l.points];
    # The right margin fits the longest end label, at about 7px a character.
    longest = max([len(f"{l.label} {pct(l.points[-1][1])}") for l in shown] + [0]);
    (left, right, top, bottom) = (64, 24 + 7 * longest, 64, 40);
    days = sorted({d for l in shown for (d, _) in l.points});
    if not days {
        return "";
    }
    values = [v for l in shown for (_, v) in l.points] + [0.0];
    marks = ticks(min(values), max(values));
    (lo, hi) = (marks[0], marks[-1]);
    plot_w = width - left - right;
    plot_h = height - top - bottom;
    index = {d: i for (i, d) in enumerate(days)};
    def x(day: str) -> float {
        return left + (index[day] / (len(days) - 1) * plot_w if len(days) > 1 else plot_w / 2);
    }
    def y(v: float) -> float {
        return top + (hi - v) / (hi - lo) * plot_h if hi > lo else top + plot_h / 2;
    }
    out = [f"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {width} {height}\" width=\"{width}\" height=\"{height}\" role=\"img\" aria-label=\"{esc(title)}\">", STYLE];
    out.append(f"<rect class=\"surface\" width=\"{width}\" height=\"{height}\" rx=\"8\"/>");
    out.append(f"<text class=\"ink title\" x=\"{left}\" y=\"24\">{esc(title)}</text>");
    lx = left;
    for (i, l) in enumerate(shown) {
        out.append(f"<line class=\"s{i % 3 + 1}\" x1=\"{lx}\" y1=\"44\" x2=\"{lx + 18}\" y2=\"44\" stroke-width=\"2\" stroke-linecap=\"round\"/>");
        out.append(f"<text class=\"muted\" x=\"{lx + 24}\" y=\"48\">{esc(l.label)}</text>");
        lx += 24 + 7 * len(l.label) + 20;
    }
    for m in marks {
        out.append(f"<line class=\"{'axis' if m == 0 else 'grid'}\" x1=\"{left}\" y1=\"{y(m):.1f}\" x2=\"{left + plot_w}\" y2=\"{y(m):.1f}\" stroke-width=\"1\"/>");
        out.append(f"<text class=\"muted\" x=\"{left - 8}\" y=\"{y(m) + 4:.1f}\" text-anchor=\"end\">{tick_label(m)}</text>");
    }
    count = min(5, len(days));
    picks = sorted({round(i * (len(days) - 1) / max(count - 1, 1)) for i in range(count)});
    for i in picks {
        anchor = "start" if i == 0 and len(days) > 1 else ("end" if i == len(days) - 1 and len(days) > 1 else "middle");
        out.append(f"<text class=\"muted\" x=\"{x(days[i]):.1f}\" y=\"{height - bottom + 20}\" text-anchor=\"{anchor}\">{days[i]}</text>");
    }
    ends: list[tuple[float, int]] = [];
    for (i, l) in enumerate(shown) {
        path = " ".join(f"{'M' if j == 0 else 'L'}{x(d):.1f},{y(v):.1f}" for (j, (d, v)) in enumerate(l.points));
        out.append(f"<path class=\"s{i % 3 + 1}\" d=\"{path}\" fill=\"none\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>");
        ends.append((y(l.points[-1][1]), i));
    }
    # End labels keep at least 16px apart, top to bottom, so close lines stay readable.
    placed: list[tuple[float, int]] = [];
    for (ey, i) in sorted(ends) {
        ny = max(ey, placed[-1][0] + 16) if placed else ey;
        placed.append((ny, i));
    }
    for (ny, i) in placed {
        l = shown[i];
        (d, v) = l.points[-1];
        out.append(f"<circle class=\"f{i % 3 + 1}\" cx=\"{x(d):.1f}\" cy=\"{y(v):.1f}\" r=\"4\"/>");
        out.append(f"<text class=\"ink\" x=\"{left + plot_w + 10}\" y=\"{ny + 4:.1f}\">{esc(l.label)} {pct(v)}</text>");
    }
    out.append("</svg>");
    return "\n".join(out) + "\n";
}

"""One row of the calibration chart: stated confidence against hit rate with its interval."""
obj CalibrationRow {
    has label: str,
        confidence: float,
        hit_rate: float;
    has lo: float | None = None,
        hi: float | None = None,
        votes: int = 0;
}

"""Each specialist's stated confidence (hollow) against its hit rate (filled) with the hit
rate's 95% interval, on one 0 to 100% axis. A well-calibrated row has the two dots together."""
def calibration_chart(rows: list[CalibrationRow]) -> str {
    if not rows {
        return "";
    }
    (width, left, right, top) = (760, 150, 40, 70);
    gap = 36;
    height = top + gap * len(rows) + 16;
    plot_w = width - left - right;
    def x(v: float) -> float {
        return left + max(0.0, min(1.0, v)) * plot_w;
    }
    title = "Stated confidence against hit rate, by specialist";
    out = [f"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {width} {height}\" width=\"{width}\" height=\"{height}\" role=\"img\" aria-label=\"{title}\">", STYLE];
    out.append(f"<rect class=\"surface\" width=\"{width}\" height=\"{height}\" rx=\"8\"/>");
    out.append(f"<text class=\"ink title\" x=\"24\" y=\"24\">{title}</text>");
    out.append("<circle class=\"hollow\" cx=\"30\" cy=\"44\" r=\"5\" stroke-width=\"2\"/><text class=\"muted\" x=\"42\" y=\"48\">Mean stated confidence</text>");
    out.append("<circle class=\"f1\" cx=\"216\" cy=\"44\" r=\"5\"/><line class=\"range\" x1=\"230\" y1=\"44\" x2=\"250\" y2=\"44\" stroke-width=\"2\" stroke-linecap=\"round\"/><text class=\"muted\" x=\"258\" y=\"48\">Hit rate with its 95% interval</text>");
    bottom_y = top + gap * len(rows) - gap / 2;
    for m in [0.0, 0.25, 0.5, 0.75, 1.0] {
        out.append(f"<line class=\"grid\" x1=\"{x(m):.1f}\" y1=\"{top - 10}\" x2=\"{x(m):.1f}\" y2=\"{bottom_y:.1f}\" stroke-width=\"1\"/>");
        out.append(f"<text class=\"muted\" x=\"{x(m):.1f}\" y=\"{bottom_y + 20:.1f}\" text-anchor=\"middle\">{pct(m, False, 0)}</text>");
    }
    for (i, r) in enumerate(rows) {
        cy = top + gap * i + 6;
        out.append(f"<text class=\"ink\" x=\"{left - 16}\" y=\"{cy + 4}\" text-anchor=\"end\">{esc(r.label)}</text>");
        if r.lo is not None and r.hi is not None {
            out.append(f"<line class=\"range\" x1=\"{x(r.lo):.1f}\" y1=\"{cy}\" x2=\"{x(r.hi):.1f}\" y2=\"{cy}\" stroke-width=\"2\" stroke-linecap=\"round\"/>");
        }
        out.append(f"<circle class=\"hollow\" cx=\"{x(r.confidence):.1f}\" cy=\"{cy}\" r=\"5\" stroke-width=\"2\"/>");
        out.append(f"<circle class=\"f1\" cx=\"{x(r.hit_rate):.1f}\" cy=\"{cy}\" r=\"5\"/>");
    }
    out.append("</svg>");
    return "\n".join(out) + "\n";
}

# --- Sections -----------------------------------------------------------------------------

glob SERIES_LABELS: dict[str, str] = {"team": "Parallax", "equal_weight": "Equal-weight shortlist", "spy": "SPY buy-and-hold"};
glob AGAINST: dict[str, str] = {"equal_weight": "the equal-weight shortlist", "spy": "SPY buy-and-hold"};
glob SPECIALIST_LABELS: dict[str, str] = {"fundamentals": "Fundamentals", "technical": "Technical", "news": "News", "macro": "Macro", "flow": "Flow"};

def series_label(key: str, fallback: str = "") -> str {
    return SERIES_LABELS.get(key, fallback or key);
}

"""The equity curves of get_performance, as cumulative-return lines in fixed order."""
def forward_lines(performance: dict[str, object]) -> list[Line] {
    lines: list[Line] = [];
    found = {text(s, "key"): s for s in records(performance, "series")};
    for key in ["team", "equal_weight", "spy"] {
        s = found.get(key);
        if s is not None {
            points = [(text(p, "day"), number(p, "equity") or 0.0) for p in records(s, "points")];
            lines.append(Line(key=key, label=series_label(key, text(s, "label")), points=returns_from(points)));
        }
    }
    return lines;
}

"""The answer-first bullets: each comparison, the backtest's adoption, and the replay's hit rate."""
def headline(evaluation: dict[str, object] | None, backtest: dict[str, object] | None, replay: dict[str, object] | None) -> list[str] {
    found: list[str] = [];
    if evaluation is not None {
        if flag(evaluation, "demo") {
            found.append("- **Demo data.** The forward test here is the simulated demo history, not paper trading, so its figures are not results.");
        }
        for c in records(evaluation, "comparisons") {
            against = AGAINST.get(text(c, 'baseline'), text(c, 'label'));
            sessions = whole(c, "sessions");
            if sessions < MIN_SESSIONS {
                found.append(f"- **Against {against}**, there is {thin(sessions, MIN_SESSIONS, 'matched sessions')} for a verdict.");
            } else {
                found.append(f"- **Against {against}**, Parallax is {verdict_words(text(c, 'verdict'))}: {estimate(record(c, 'excess_return'))} over {plural(sessions, 'matched session')}.");
            }
        }
        if not records(evaluation, "comparisons") {
            found.append("- The forward test has no baseline to compare against yet.");
        }
    } else {
        found.append("- The forward test's evaluation is missing; run the report against the server to fetch it.");
    }
    if backtest is not None {
        chosen = record(backtest, "chosen");
        adopted = record(backtest, "adopted");
        what = [n for (n, k) in [("the screen", "screen"), ("the stop multiple", "stop_atr_multiple")] if flag(adopted, k)];
        found.append(f"- **The screen backtest** chose screen `{text(chosen, 'screen')}` with a {number(chosen, 'stop_atr_multiple')} ATR stop; " + (f"{' and '.join(what)} {'was' if len(what) == 1 else 'were'} adopted." if what else "nothing beat the current settings on validation, so nothing was adopted."));
    }
    if replay is not None {
        s = record(replay, "summary");
        directional = whole(s, "directional_votes");
        if not replay_complete(replay) {
            found.append(f"- **The LLM replay** is still under way ({days_phrase(replay)}), so it is not a benchmark; its figures so far are under [LLM replay](#llm-replay-partial).");
        } elif directional < MIN_VOTES {
            found.append(f"- **The LLM replay** finished on {days_phrase(replay)}, with {thin(directional, MIN_VOTES, 'directional votes')} for a hit rate.");
        } else {
            found.append(f"- **The LLM replay** called {pct(number(s, 'hit_rate'), False, 0)} of {directional} directional votes right (95% interval {span(pair(s, 'hit_rate_ci'), False, 0)}) on {days_phrase(replay)}.");
        }
    }
    return found;
}

def forward_section(forward: dict[str, object] | None, figures: dict[str, str]) -> list[str] {
    evaluation = record(forward, "evaluation") if forward is not None else {};
    out = ["## Forward test: simulated demo data" if flag(evaluation, "demo") else "## Forward test: live paper trading", ""];
    if flag(evaluation, "demo") {
        out.extend(["**Demo data.** This evaluation is of the simulated demo history, with made-up prices and votes. Nothing in it was traded, so it is not a result.", ""]);
    }
    if not evaluation {
        out.extend(["No evaluation is stored yet: the server writes one after the first evening review that follows a run.", ""]);
        return out;
    }
    start = text(evaluation, "start_day");
    out.append(f"The forward test started on {start} and this covers {plural(whole(evaluation, 'sessions'), 'trading session')} through {text(evaluation, 'last_day')}.");
    out.append("Each portfolio starts from its own cash and is marked at every close; Sharpe ratios are annualized with no risk-free rate.");
    out.append("");
    rows = [[series_label(text(s, "key"), text(s, "label")), pct(number(s, "total_return")), ratio(number(s, "sharpe")), pct(number(s, "max_drawdown"), False), str(whole(s, "sessions"))] for s in records(evaluation, "series")];
    out.extend([table(["Portfolio", "Total return", "Sharpe", "Max drawdown", "Sessions"], rows), ""]);
    lines = forward_lines(record(forward, "performance") if forward is not None else {});
    svg = line_chart(f"Return since {start}", lines);
    if svg {
        figures["forward-test.svg"] = svg;
        out.extend(["![Return of Parallax and both baselines since the start of the forward test](figures/forward-test.svg)", ""]);
    }
    comparisons = records(evaluation, "comparisons");
    if comparisons {
        out.append("The comparison pairs the sessions both portfolios marked and resamples their daily returns in blocks of five sessions, so a verdict appears only when the 95% interval leaves out zero.");
        out.append("");
        crow: list[list[str]] = [];
        for c in comparisons {
            sessions = whole(c, "sessions");
            if sessions < MIN_SESSIONS {
                crow.append([series_label(text(c, "baseline"), text(c, "label")), str(sessions), thin(sessions, MIN_SESSIONS, "sessions"), "n/a", "not enough data"]);
            } else {
                crow.append([series_label(text(c, "baseline"), text(c, "label")), str(sessions), estimate(record(c, "excess_return")), estimate(record(c, "sharpe_difference"), True, True), verdict_words(text(c, "verdict"))]);
            }
        }
        out.extend([table(["Baseline", "Matched sessions", "Excess return", "Sharpe difference", "Verdict"], crow), ""]);
    }
    out.extend(attribution(evaluation, figures));
    out.extend(operations_section(evaluation));
    return out;
}

def attribution(evaluation: dict[str, object], figures: dict[str, str]) -> list[str] {
    out = ["### Where the result came from", ""];
    screen = record(evaluation, "screen");
    runs = whole(screen, "runs");
    if 0 < runs < MIN_SESSIONS {
        out.append(f"**Screen.** There is {thin(runs, MIN_SESSIONS, 'scored runs')}; a run's screen is scored ten sessions after it.");
    } elif runs {
        out.append(f"**Screen.** Over {plural(runs, 'scored run')}, the shortlisted names returned {pct(number(screen, 'picks_excess'), True, 2)} against SPY over the next ten sessions, and the rest of the S&P 500 {pct(number(screen, 'rest_excess'), True, 2)}.");
        out.append(f"The spread is {estimate(record(screen, 'spread'))}, and the picks led in {whole(screen, 'positive_runs')} of {runs} runs.");
    } else {
        out.append("**Screen.** No run's ten-session window has closed yet, so the screen has no score.");
    }
    out.append("");
    arbiter = record(evaluation, "arbiter");
    blocked = whole(arbiter, "blocked");
    if 0 < blocked < MIN_SESSIONS {
        out.append(f"**Arbiter.** There is {thin(blocked, MIN_SESSIONS, 'scored blocked buys')} to say whether blocking them helped.");
    } elif blocked {
        out.append(f"**Arbiter.** The {plural(blocked, 'buy')} it downgraded would have returned {estimate(record(arbiter, 'blocked_excess'))} against SPY over ten sessions, {arbiter_words(text(arbiter, 'verdict'))}.");
        out.append(f"The {plural(whole(arbiter, 'confirmed'), 'buy')} it confirmed returned {estimate(record(arbiter, 'confirmed_excess'))}.");
    } else {
        out.append("**Arbiter.** No downgraded buy has been scored yet.");
    }
    out.append("");
    specialists = records(evaluation, "specialists");
    if specialists {
        out.append(f"**Specialist calibration.** A specialist is calibrated when its hit rate on BUY and SELL votes is within 10 points of its mean stated confidence; a hit rate shows from {MIN_VOTES} scored votes.");
        out.append("");
        srows: list[list[str]] = [];
        chart: list[CalibrationRow] = [];
        for s in specialists {
            hit = record(s, "hit_rate");
            within = flag(s, "within_target");
            label = SPECIALIST_LABELS.get(text(s, "specialist"), text(s, "specialist").title());
            votes = whole(s, "votes");
            if votes < MIN_VOTES {
                srows.append([label, str(votes), pct(number(s, "confidence"), False, 0), thin(votes, MIN_VOTES, "scored votes") if votes else "n/a", "n/a", "n/a"]);
                continue;
            }
            srows.append([label, str(votes), pct(number(s, "confidence"), False, 0), estimate(hit, False), pct(number(s, "gap"), True, 0), "yes" if within else ("no" if within is not None else "n/a")]);
            (conf, rate) = (number(s, "confidence"), number(hit, "value"));
            if conf is not None and rate is not None {
                chart.append(CalibrationRow(label=label, confidence=conf, hit_rate=rate, lo=number(hit, "lo"), hi=number(hit, "hi"), votes=whole(s, "votes")));
            }
        }
        out.extend([table(["Specialist", "Scored votes", "Confidence", "Hit rate", "Gap", "Within 10 points"], srows), ""]);
        svg = calibration_chart(chart);
        if svg {
            figures["calibration.svg"] = svg;
            out.extend(["![Each specialist's mean stated confidence against its hit rate](figures/calibration.svg)", ""]);
        } else {
            out.extend([f"No specialist has {MIN_VOTES} scored votes yet, so there is no calibration chart.", ""]);
        }
    } else {
        out.extend(["**Specialist calibration.** No directional vote has been scored yet.", ""]);
    }
    return out;
}

def operations_section(evaluation: dict[str, object]) -> list[str] {
    r = record(evaluation, "reliability");
    o = record(evaluation, "operations");
    out = ["### Reliability and operations", ""];
    out.append(f"{whole(r, 'complete')} of {plural(whole(r, 'sessions'), 'trading session')} ({pct(number(r, 'share'), False, 0)}) had a run that finished with a decision for every covered ticker; the target is 95%.");
    missed = texts(r, "missed");
    incomplete = texts(r, "incomplete");
    if missed {
        out.append(f"Sessions without a run: {', '.join(missed)}.");
    }
    if incomplete {
        out.append(f"Incomplete runs: {'; '.join(incomplete)}.");
    }
    median = number(o, "latency_median_minutes");
    if median is not None {
        out.append(f"Runs took a median of {median:.0f} minutes from preflight to their decisions, at most {number(o, 'latency_max_minutes') or 0.0:.0f}, and {whole(o, 'under_two_hours')} finished within two hours.");
    }
    out.append(f"Orders outside the risk gate: {whole(o, 'bypasses')}.");
    per_run = number(o, "requests_per_run");
    if per_run is not None {
        busiest = whole(o, "peak_daily_requests");
        out.append(f"Free-model requests averaged {per_run:.0f} per run (at most {whole(o, 'requests_max_run')})" + (f", and the busiest day used {busiest} of the {whole(o, 'daily_cap')} allowed." if busiest else "."));
    }
    out.append("");
    return out;
}

def portfolio_row(name: str, period: str, p: dict[str, object]) -> list[str] {
    return [name, period, pct(number(p, "total_return")), pct(number(p, "annual_return")), ratio(number(p, "sharpe")), pct(number(p, "max_drawdown"), False)];
}

def backtest_section(backtest: dict[str, object] | None, figures: dict[str, str]) -> list[str] {
    out = ["## Screen backtest: historical, no model", ""];
    if backtest is None {
        out.extend([f"Not available: `{OUT_DIR}/{BACKTEST_FILE}` is missing.", ""]);
        return out;
    }
    train = texts(backtest, "train");
    valid = texts(backtest, "validation");
    data = record(backtest, "data");
    out.append(f"The backtest replays the screen, sizing, and risk gate with no model, on S&P 500 membership as of each decision day, choosing settings on {' to '.join(train)} and checking them on {' to '.join(valid)}.");
    out.append(f"It covers {whole(data, 'decision_days')} decision days over {whole(data, 'sessions')} sessions and {whole(data, 'symbols')} symbols, with news sampled {text(data, 'news') or 'n/a'}; see [the findings](screen-backtest.md) for the method and limits.");
    out.append("");
    rows: list[list[str]] = [];
    for v in records(backtest, "variants") {
        for (period, key) in [("train", "train"), ("validation", "validation")] {
            p = record(v, key);
            portfolio = record(p, "portfolio");
            rows.append([f"`{text(v, 'name')}`" if period == "train" else "", period, str(whole(p, "days")), pct(number(p, "spread"), True, 2), span(pair(p, "spread_ci"), True, 2), ratio(number(portfolio, "sharpe")), pct(number(portfolio, "max_drawdown"), False)]);
        }
    }
    if rows {
        out.extend([table(["Variant", "Period", "Days", "Screen spread", "Spread 95% interval", "Sharpe", "Max drawdown"], rows), ""]);
    }
    spy = record(backtest, "spy");
    out.extend([table(["Benchmark", "Period", "Total return", "Annual return", "Sharpe", "Max drawdown"], [portfolio_row("SPY", "train", record(spy, "train")), portfolio_row("SPY", "validation", record(spy, "validation"))]), ""]);
    current = record(backtest, "current");
    chosen = record(backtest, "chosen");
    out.append(f"The current settings are screen `{text(current, 'screen')}` with a {number(current, 'stop_atr_multiple')} ATR stop; training chose `{text(chosen, 'screen')}` with {number(chosen, 'stop_atr_multiple')}.");
    if text(backtest, "reason") {
        out.append(text(backtest, "reason"));
    }
    out.append("");
    curves = record(record(backtest, "curves"), "validation");
    lines: list[Line] = [];
    same = text(current, "screen") == text(chosen, "screen") and number(current, "stop_atr_multiple") == number(chosen, "stop_atr_multiple");
    for (key, label) in [("current", "Current settings"), ("chosen", "Chosen settings"), ("spy", "SPY")] {
        if key == "chosen" and same {
            continue;
        }
        raw = curves.get(key);
        points = [(str(p[0]), float(p[1])) for p in raw if isinstance(p, list) and len(p) == 2 and isinstance(p[1], (int, float))] if isinstance(raw, list) else [];
        lines.append(Line(key=key, label=label, points=returns_from(points)));
    }
    svg = line_chart("Backtest return over the validation period", lines);
    if svg {
        figures["backtest-validation.svg"] = svg;
        out.extend(["![Backtest return of the current and chosen settings against SPY over the validation period](figures/backtest-validation.svg)", ""]);
    }
    return out;
}

"""The replay's days with a decision, in order, and how many it planned."""
def replay_days(replay: dict[str, object]) -> tuple[list[str], int] {
    done = sorted({text(d, "day") for d in records(replay, "decisions") if text(d, "day")});
    return (done, len(texts(replay, "days")));
}

"""True when the replay finished every day it planned."""
def replay_complete(replay: dict[str, object]) -> bool {
    (done, planned) = replay_days(replay);
    return len(done) >= planned;
}

def days_phrase(replay: dict[str, object]) -> str {
    (done, planned) = replay_days(replay);
    return plural(len(done), "past day") if len(done) >= planned else f"{len(done)} of {plural(planned, 'planned past day')}, so far";
}

def replay_section(replay: dict[str, object] | None) -> list[str] {
    if replay is None {
        return ["## LLM replay", "", f"Not available: `{OUT_DIR}/{REPLAY_FILE}` is missing.", ""];
    }
    complete = replay_complete(replay);
    out = ["## LLM replay" + ("" if complete else " (partial)"), ""];
    if not complete {
        out.extend([f"**Partial.** The replay is still under way: it has run on {days_phrase(replay)}. Its figures describe only those days and are not a benchmark.", ""]);
    }
    s = record(replay, "summary");
    (days, _) = replay_days(replay);
    span_text = f" ({days[0]} to {days[-1]})" if len(days) > 1 else (f" ({days[0]})" if days else "");
    out.append(f"The full pipeline ran on {days_phrase(replay)}{span_text} for {', '.join(texts(replay, 'tickers'))}, with one panel sample and only data dated before each morning, using `{text(replay, 'model')}` (trained through {text(replay, 'model_cutoff') or 'an unknown date'}).");
    out.append("See [the findings](llm-replay.md) for the method and limits.");
    out.append("");
    rows = [
        ["Ticker-days that finished with a valid decision", f"{whole(s, 'complete')} of {whole(s, 'pairs')}"],
        ["Votes that parsed", f"{whole(s, 'valid_votes')} of {whole(s, 'votes')}"],
        ["Directional votes right over ten sessions", f"{pct(number(s, 'hit_rate'), False, 0)} of {whole(s, 'directional_votes')} (95% interval {span(pair(s, 'hit_rate_ci'), False, 0)})" if whole(s, "directional_votes") >= MIN_VOTES else thin(whole(s, "directional_votes"), MIN_VOTES, "directional votes")],
        ["Buys and their mean excess return over SPY", f"{whole(s, 'buys')}, {pct(number(s, 'buy_mean_excess'), True, 2)}"],
        ["Evidence dated after the decision time", str(whole(s, "late_evidence_count"))],
        ["Model requests and wall time", f"{whole(replay, 'requests_used')}, {number(replay, 'wall_minutes') or 0.0:.0f} minutes"]
    ];
    out.extend([table(["Check", "Result"], rows), ""]);
    audit = records(replay, "audit");
    if audit {
        out.append("Every data source was bounded to the replay morning, stripped of later fields, or dropped:");
        out.append("");
        out.extend([table(["Source", "Treatment", "Detail"], [[text(a, "source"), text(a, "treatment"), text(a, "detail")] for a in audit]), ""]);
    }
    notes = texts(s, "notes");
    if notes {
        out.extend(["Run details:", ""] + [f"- {n}" for n in notes] + [""]);
    }
    return out;
}

def limits_section(forward: dict[str, object] | None, backtest: dict[str, object] | None) -> list[str] {
    notes = texts(record(forward, "evaluation"), "notes") if forward is not None else [];
    notes += texts(record(backtest, "data"), "notes") if backtest is not None else [];
    out = ["## Limits", ""];
    out.append("- The forward test is a few weeks of paper trading, so its intervals are wide; a verdict of not clear yet is the expected result, not a failure.");
    out.append("- Alpaca simulates paper fills from live quotes, so the forward test leaves out market impact.");
    out.extend([f"- {n}" for n in notes]);
    out.append("");
    return out;
}

"""The report's Markdown and its SVG figures by file name, from the inputs alone: the same inputs
always give the same report. Every input may be None."""
def render(forward: dict[str, object] | None, backtest: dict[str, object] | None, replay: dict[str, object] | None) -> tuple[str, dict[str, str]] {
    figures: dict[str, str] = {};
    evaluation = record(forward, "evaluation") if forward is not None else {};
    out = ["# Parallax final evaluation", ""];
    last_day = text(evaluation, "last_day");
    snapshot = text(evaluation, "snapshot");
    if last_day {
        out.append(f"Built from the forward test's stored evaluation through the {last_day} close" + (f" (snapshot `{snapshot}`, stored {text(evaluation, 'as_of')}, the ID the Results page shows)" if snapshot else f" (stored {text(evaluation, 'as_of')})") + ", the screen backtest, and the LLM replay.");
    } else {
        out.append("Built from the screen backtest and the LLM replay; the forward test has no stored evaluation yet.");
    }
    out.append(f"Rebuild it with `{REBUILD}`; the module's docstring lists the settings.");
    out.append("");
    out.extend(["## Answer first", ""] + headline(evaluation or None, backtest, replay) + [""]);
    out.extend(forward_section(forward, figures));
    out.extend(backtest_section(backtest, figures));
    out.extend(replay_section(replay));
    out.extend(limits_section(forward, backtest));
    return ("\n".join(out).rstrip() + "\n", figures);
}

# --- Fetching and writing -----------------------------------------------------------------

def post(base: str, path: str, body: dict[str, object], token: str = "") -> dict[str, object] {
    headers = {"Authorization": f"Bearer {token}"} if token else {};
    response = httpx.post(base.rstrip("/") + path, json=body, headers=headers, timeout=180);
    response.raise_for_status();
    raw = response.json();
    return {str(k): v for (k, v) in raw.items()} if isinstance(raw, dict) else {};
}

"""The admin's (the team's) evaluation and equity curves from a running server."""
def fetch(base: str, username: str, password: str) -> dict[str, object] {
    login = post(base, "/user/login", {"identity": {"type": "username", "value": username}, "credential": {"type": "password", "password": password}});
    token = text(record(login, "data"), "token");
    if not token {
        raise RuntimeError(f"could not sign in to {base} as {username}");
    }
    evaluation = record(post(base, "/function/get_evaluation", {}, token), "data").get("result");
    performance = record(post(base, "/function/get_performance", {}, token), "data").get("result");
    return {"fetched_at": datetime.now(timezone.utc).isoformat(), "evaluation": evaluation, "performance": performance};
}

"""Write the report and its figures under `out_dir`, replacing figures it no longer draws."""
def write_report(out_dir: Path, markdown: str, figures: dict[str, str]) {
    folder = out_dir / "figures";
    folder.mkdir(parents=True, exist_ok=True);
    for name in ["forward-test.svg", "calibration.svg", "backtest-validation.svg"] {
        if name not in figures and (folder / name).exists() {
            (folder / name).unlink();
        }
    }
    for (name, svg) in figures.items() {
        (folder / name).write_text(svg);
    }
    (out_dir / REPORT_FILE).write_text(markdown);
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        out_dir = Path(os.environ.get("REPORT_OUT", OUT_DIR));
        out_dir.mkdir(parents=True, exist_ok=True);
        if os.environ.get("REPORT_OFFLINE") != "1" {
            password = os.environ.get("REPORT_PASSWORD") or os.environ.get("ADMIN_PASSWORD", "");
            forward = fetch(os.environ.get("REPORT_URL", "http://localhost:8100"), os.environ.get("REPORT_USERNAME", "admin"), password);
            (out_dir / FORWARD_FILE).write_text(json.dumps(forward, indent=1) + "\n");
        }
        (markdown, figures) = render(load(out_dir / FORWARD_FILE), load(out_dir / BACKTEST_FILE), load(out_dir / REPLAY_FILE));
        write_report(out_dir, markdown, figures);
        sys.stdout.write(f"wrote {out_dir / REPORT_FILE} with {len(figures)} figures\n");
    }
}

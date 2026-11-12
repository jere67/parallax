"""The deterministic historical harness (TDD §13, historical harness): the screen, sizing, and
risk gate replayed on every session from 2016 on, with no model calls.

On each decision day D the harness rebuilds what `research/screener.jac` `gather` would have
read that morning, from bars through the session before D only:

- the screen's price and volume terms from the bars of the year before (the indicators'
  own functions, as `summarize` computes them),
- the articles naming each member from the start of the third session before D to 7:30 a.m.
  New York time on D,
- an earnings flag for an 8-K Item 2.02 filed within the five sessions from D,

and runs the live `screen()` on the members of that day. Each day's shortlist is then scored
two ways:

- **Hit rate.** The picks' mean excess return over SPY minus that of the other liquid members,
  on the window votes are scored on (analysis/scoring.jac, `vote_window`): the last close
  before D to the close of the tenth session counting D.
- **Portfolio.** The equal-weight shortlist baseline (action/baselines.jac,
  `simulate_equal_weight`) trades the picks through the real sizing and risk gate, beside
  SPY buy-and-hold (`simulate_spy`). The runs, positions, and marks it writes are in-memory
  nodes on no root, so nothing is stored.

Intervals are moving-block bootstrap percentiles, since overlapping ten-session windows and
daily returns are autocorrelated.
"""
import bisect;
import math;
import random;
import statistics;
import from datetime { date, datetime, time, timedelta, timezone }
import from zoneinfo { ZoneInfo }
import from action.baselines { SimDay, sim_marks, sim_positions, simulate_equal_weight, simulate_spy }
import from action.gate { GateConfig }
import from action.sizing { SizingConfig }
import from analysis.scoring { BENCHMARK, vote_window }
import from models.agents { MacroReport, RiskRegime }
import from models.graph { Baseline, BaselineKind, Coverage, CoverageReason, Covers, HasMacro, MacroRecord, Run, RunStatus }
import from models.research { RegimeInputs }
import from research.alpaca { Bar }
import from research.indicators { atr, dollar_volume, momentum, realized_vol, relative_volume, sma }
import from research.screener { Candidate, PickReason, ScreenConfig, Shortlist, screen }

glob NEW_YORK: ZoneInfo = ZoneInfo("America/New_York");
glob TRADING_DAYS: int = 252;
glob HORIZON: int = 10;
# The morning run reads news up to its start (run/jobs.jac).
glob RUN_START: time = time(7, 30);
glob LOOKBACK_DAYS: int = 366;
# Sessions of bars a simulated day reads before itself, as the baselines' LOOKBACK_DAYS does.
glob SIM_LOOKBACK_SESSIONS: int = 10;
glob STARTING_CASH: float = 100e3;
glob BLOCK: int = 10;
glob RESAMPLES: int = 2000;
glob SEED: int = 449;

"""One symbol's daily bars as parallel columns, oldest first."""
obj Prices {
    has symbol: str,
        days: list[str],
        opens: list[float],
        highs: list[float],
        lows: list[float],
        closes: list[float],
        volumes: list[float];
    has _bars: list[Bar] | None = None;

    """How many bars fall on or before `day`."""
    def through(day: str) -> int {
        return bisect.bisect_right(self.days, day);
    }

    def close_on(day: str) -> float | None {
        i = bisect.bisect_left(self.days, day);
        return self.closes[i] if i < len(self.days) and self.days[i] == day else None;
    }

    """The bars from `first` through `last`, by day."""
    def window(first: str, last: str) -> dict[str, Bar] {
        if self._bars is None {
            self._bars = [
                Bar(day=d, open=o, high=h, low=l, close=c, volume=v, trades=0, vwap=c)
                for (d, o, h, l, c, v) in zip(self.days, self.opens, self.highs, self.lows, self.closes, self.volumes)
            ];
        }
        found = self._bars[bisect.bisect_left(self.days, first):self.through(last)];
        return {b.day: b for b in found};
    }
}

def prices_of(symbol: str, bars: list[Bar]) -> Prices {
    return Prices(
        symbol=symbol,
        days=[b.day for b in bars],
        opens=[b.open for b in bars],
        highs=[b.high for b in bars],
        lows=[b.low for b in bars],
        closes=[b.close for b in bars],
        volumes=[b.volume for b in bars],
        _bars=bars
    );
}

"""The figures the screen and the gate read for one stock on one morning, as `summarize` gives
them from a year of bars through the last session."""
obj Inputs {
    has close: float,
        momentum_20: float | None,
        momentum_60: float | None,
        rvol_5: float | None,
        vol_20: float | None,
        dollar_volume_20: float | None,
        atr_14: float | None,
        volume_20: float | None,
        sma_200: float | None;
}

"""`p`'s inputs from the bars of the year through `last_session`, never a later one, or None
when it has no bar on `last_session` (it did not trade that day)."""
def inputs_on(p: Prices, last_session: str) -> Inputs | None {
    end = p.through(last_session);
    if end == 0 or p.days[end - 1] != last_session {
        return None;
    }
    start = bisect.bisect_left(p.days, (date.fromisoformat(last_session) - timedelta(days=LOOKBACK_DAYS)).isoformat());
    closes = p.closes[start:end];
    highs = p.highs[start:end];
    lows = p.lows[start:end];
    volumes = p.volumes[start:end];
    return Inputs(
        close=closes[-1],
        momentum_20=momentum(closes, 20),
        momentum_60=momentum(closes, 60),
        rvol_5=relative_volume(volumes, 5, 60),
        vol_20=realized_vol(closes, 20),
        dollar_volume_20=dollar_volume(closes, volumes, 20),
        atr_14=atr(highs, lows, closes, 14),
        volume_20=sma(volumes, 20),
        sma_200=sma(closes, 200)
    );
}

"""Article timestamps by symbol, for counts over any interval."""
obj NewsIndex {
    has times: dict[str, list[str]];

    """Articles naming `symbol` from `start` up to, not including, `end` (UTC "...Z" stamps)."""
    def count(symbol: str, start: str, end: str) -> int {
        found = self.times.get(symbol);
        if not found {
            return 0;
        }
        return bisect.bisect_left(found, end) - bisect.bisect_left(found, start);
    }
}

"""An index of `articles` ([created_at, [symbols]]), with every stamp written as
"YYYY-MM-DDTHH:MM:SSZ" so stamps compare as text."""
def news_index(articles: list[any]) -> NewsIndex {
    times: dict[str, list[str]] = {};
    for row in articles {
        stamp = utc_text(datetime.fromisoformat(str(row[0]).replace("Z", "+00:00")));
        for symbol in row[1] {
            times.setdefault(str(symbol), []).append(stamp);
        }
    }
    for found in times.values() {
        found.sort();
    }
    return NewsIndex(times=times);
}

def utc_text(when: datetime) -> str {
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ");
}

"""Who was in the index and how to group it, on any day."""
obj Universe {
    has members: dict[str, list[str]],
        sectors: dict[str, dict[str, str]],
        current_sectors: dict[str, str],
        companies: dict[str, str],
        releases: dict[str, list[str]];

    """`symbol`'s GICS sector as the table of `year` lists it, else the nearest year's, else
    today's; a symbol no table lists gets a sector of its own, so the cap never binds it."""
    def sector(symbol: str, year: int) -> str {
        for offset in [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8, 8, -9, 9] {
            row = self.sectors.get(str(year + offset), {}).get(symbol);
            if row {
                return row;
            }
        }
        return self.current_sectors.get(symbol) or f"Unknown ({symbol})";
    }

    """The first session in `ahead` with an earnings release, counted from 0, or None."""
    def sessions_to_earnings(symbol: str, ahead: list[str]) -> int | None {
        found = self.releases.get(self.companies.get(symbol, ""), []);
        if not found or not ahead {
            return None;
        }
        i = bisect.bisect_left(found, ahead[0]);
        if i == len(found) or found[i] > ahead[-1] {
            return None;
        }
        return bisect.bisect_left(ahead, found[i]);
    }
}

"""One morning's screen inputs: the candidates, and the gate's figures for each."""
obj Morning {
    has day: str,
        candidates: list[Candidate],
        inputs: dict[str, Inputs],
        sectors: dict[str, str],
        to_earnings: dict[str, int | None],
        regime: RegimeInputs | None;
}

"""What `gather` would have built on `sessions[k]`'s morning: bars through the session before,
news from the third session before to the run's start, and releases in the five sessions from
the day. Every member is a candidate; one with no bar on the last session is untradable."""
def morning(k: int, sessions: list[str], universe: Universe, prices: dict[str, Prices], news: NewsIndex, config: ScreenConfig = ScreenConfig()) -> Morning {
    day = sessions[k];
    last = sessions[k - 1];
    news_start = sessions[k - config.news_sessions] + "T00:00:00Z";
    news_end = utc_text(datetime.combine(date.fromisoformat(day), RUN_START, NEW_YORK));
    ahead = sessions[k:k + config.earnings_sessions];
    year = int(day[:4]);
    found = Morning(day=day, candidates=[], inputs={}, sectors={}, to_earnings={}, regime=None);
    for symbol in universe.members.get(day, []) {
        p = prices.get(symbol);
        got = inputs_on(p, last) if p is not None else None;
        sector = universe.sector(symbol, year);
        soon = universe.sessions_to_earnings(symbol, ahead);
        found.sectors[symbol] = sector;
        found.to_earnings[symbol] = soon;
        if got is not None {
            found.inputs[symbol] = got;
        }
        found.candidates.append(Candidate(
            symbol=symbol,
            name=symbol,
            company=universe.companies.get(symbol) or symbol,
            sector=sector,
            tradable=got is not None,
            momentum_20=got.momentum_20 if got else None,
            momentum_60=got.momentum_60 if got else None,
            rvol_5=got.rvol_5 if got else None,
            vol_20=got.vol_20 if got else None,
            dollar_volume_20=got.dollar_volume_20 if got else None,
            news_3=news.count(symbol, news_start, news_end),
            earnings_soon=soon is not None
        ));
    }
    spy = prices.get(BENCHMARK);
    regime = inputs_on(spy, last) if spy is not None else None;
    if regime is not None {
        found.regime = RegimeInputs(spy_close=regime.close, spy_sma_200=regime.sma_200, spy_vol_20=regime.vol_20, spy_as_of=last);
    }
    return found;
}

"""The picks' symbols, in order, from a shortlist."""
def picked(shortlist: Shortlist) -> list[str] {
    return [p.symbol for p in shortlist.picks if p.reason == PickReason.SCORE];
}

"""One day's hit rate: the picks' mean excess return over SPY, the other liquid members',
and the spread, or None when the window has not closed or a side has no prices."""
obj DayHit {
    has day: str,
        picks_mean: float,
        rest_mean: float;

    def spread -> float {
        return self.picks_mean - self.rest_mean;
    }
}

def day_hit(day: str, shortlist: Shortlist, sessions: list[str], prices: dict[str, Prices]) -> DayHit | None {
    window = vote_window(sessions, day, HORIZON);
    spy = prices.get(BENCHMARK);
    if window is None or spy is None {
        return None;
    }
    (start, end) = window;
    spy_start = spy.close_on(start);
    spy_end = spy.close_on(end);
    if not spy_start or not spy_end {
        return None;
    }
    benchmark = spy_end / spy_start - 1.0;
    chosen = set(picked(shortlist));
    picks: list[float] = [];
    rest: list[float] = [];
    for row in shortlist.scores {
        p = prices.get(row.symbol);
        if p is None {
            continue;
        }
        a = p.close_on(start);
        b = p.close_on(end);
        if not a or not b {
            continue;
        }
        (picks if row.symbol in chosen else rest).append(b / a - 1.0 - benchmark);
    }
    if not picks or not rest {
        return None;
    }
    return DayHit(day=day, picks_mean=statistics.fmean(picks), rest_mean=statistics.fmean(rest));
}

"""A run holding `shortlist`'s picks as screen coverage, with the gate's figures from
`m`, and the regime the morning read. It is on no root, so it is never stored."""
def run_of(m: Morning, shortlist: Shortlist) -> Run {
    run = Run(run_date=m.day, started_at=m.day + "T11:30:00+00:00", status=RunStatus.NORMAL, finished_at=m.day + "T13:00:00+00:00");
    for symbol in picked(shortlist) {
        got = m.inputs[symbol];
        run +>:Covers:+> Coverage(
            ticker=symbol,
            sector=m.sectors[symbol],
            reason=CoverageReason.SCREEN,
            last_close=got.close,
            atr_14=got.atr_14,
            realized_vol_20=got.vol_20,
            volume_20=got.volume_20,
            sessions_to_earnings=m.to_earnings.get(symbol)
        );
    }
    run +>:HasMacro:+> MacroRecord(as_of=m.day, model="backtest", body=MacroReport(summary="Historical harness.", regime=RiskRegime.NEUTRAL, confidence=0.5), inputs=m.regime);
    return run;
}

"""The bars a simulated session reads: SIM_LOOKBACK_SESSIONS sessions through `day`."""
def sim_day(day: str, symbols: set[str], sessions: list[str], prices: dict[str, Prices]) -> SimDay {
    k = bisect.bisect_left(sessions, day);
    first = sessions[max(0, k - SIM_LOOKBACK_SESSIONS)];
    bars: dict[str, dict[str, Bar]] = {};
    for s in symbols {
        p = prices.get(s);
        if p is None {
            continue;
        }
        found = p.window(first, day);
        if not found and p.through(day) > 0 {
            # Delisted, or halted for longer than the window: its last close still marks it.
            found = p.window(p.days[p.through(day) - 1], day);
        }
        bars[s] = found;
    }
    return SimDay(day=day, bars=bars, sessions=sessions, now=datetime.combine(date.fromisoformat(day), time(21, 0), timezone.utc));
}

"""The equal-weight shortlist through sizing and the gate over `days`, from STARTING_CASH, as
(day, equity) after each close. `runs` holds the day's run, or None when the screen picked
nothing."""
def simulate_shortlist(days: list[str], runs: dict[str, Run], sessions: list[str], prices: dict[str, Prices], gate: GateConfig, sizing: SizingConfig = SizingConfig()) -> list[tuple[str, float]] {
    if not days {
        return [];
    }
    baseline = Baseline(kind=BaselineKind.EQUAL_WEIGHT, starting_cash=STARTING_CASH, start_day=days[0], cash=STARTING_CASH, peak_equity=STARTING_CASH);
    for d in days {
        run = runs.get(d);
        symbols = set(sim_positions(baseline)) | ({c.ticker for c in [run ->:Covers:->[?:Coverage]]} if run is not None else set());
        simulate_equal_weight(baseline, sim_day(d, symbols, sessions, prices), run, sizing, gate);
    }
    marks = sim_marks(baseline);
    if marks {
        LAST_HOLDINGS[0] = {
            "mean_exposure": statistics.fmean(m.positions_value / m.equity if m.equity > 0 else 0.0 for m in marks.values()),
            "mean_positions": statistics.fmean(float(m.open_positions) for m in marks.values())
        };
    }
    return curve(baseline);
}

# How invested the last `simulate_shortlist` was on average: the share of equity in stocks, and
# the number of positions, over its marks.
glob LAST_HOLDINGS: list[dict[str, float]] = [{}];

"""SPY bought with the whole balance at the first open and held, over `days`."""
def simulate_benchmark(days: list[str], sessions: list[str], prices: dict[str, Prices]) -> list[tuple[str, float]] {
    if not days {
        return [];
    }
    baseline = Baseline(kind=BaselineKind.SPY, starting_cash=STARTING_CASH, start_day=days[0], cash=STARTING_CASH, peak_equity=STARTING_CASH);
    for d in days {
        simulate_spy(baseline, sim_day(d, {BENCHMARK}, sessions, prices));
    }
    return curve(baseline);
}

def curve(baseline: Baseline) -> list[tuple[str, float]] {
    marks = sim_marks(baseline);
    return [(d, marks[d].equity) for d in sorted(marks)];
}

"""Daily returns of an equity curve, the first measured from STARTING_CASH, as the dashboard
measures them (dashboard/api.jac, `series`)."""
def daily_returns(points: list[tuple[str, float]]) -> list[float] {
    found: list[float] = [];
    before = STARTING_CASH;
    for (_, equity) in points {
        found.append(equity / before - 1.0 if before > 0 else 0.0);
        before = equity;
    }
    return found;
}

"""Mean daily return over its sample deviation, times the square root of 252; None without
spread. The risk-free rate is zero (TDD §13)."""
def sharpe(returns: list[float]) -> float | None {
    if len(returns) < 2 {
        return None;
    }
    spread = statistics.stdev(returns);
    return statistics.fmean(returns) / spread * math.sqrt(TRADING_DAYS) if spread > 0 else None;
}

def max_drawdown(points: list[tuple[str, float]]) -> float {
    peak = STARTING_CASH;
    worst = 0.0;
    for (_, equity) in points {
        peak = max(peak, equity);
        worst = max(worst, 1.0 - equity / peak if peak > 0 else 0.0);
    }
    return worst;
}

"""Total, annualized, Sharpe, and drawdown of one curve."""
def performance(points: list[tuple[str, float]]) -> dict[str, float | None] {
    if not points {
        return {"total_return": None, "annual_return": None, "sharpe": None, "max_drawdown": None};
    }
    total = points[-1][1] / STARTING_CASH - 1.0;
    return {
        "total_return": total,
        "annual_return": (1.0 + total) ** (TRADING_DAYS / len(points)) - 1.0,
        "sharpe": sharpe(daily_returns(points)),
        "max_drawdown": max_drawdown(points)
    };
}

"""Indices of one moving-block bootstrap resample of `n` items: blocks of `block` consecutive
indices from random starts, cut to `n`."""
def block_indices(n: int, block: int, rng: random.Random) -> list[int] {
    found: list[int] = [];
    size = min(block, n);
    while len(found) < n {
        start = rng.randrange(0, n - size + 1);
        found.extend(range(start, start + size));
    }
    return found[:n];
}

"""The 2.5th and 97.5th percentiles of `stat` over moving-block resamples of `n` paired items."""
def block_interval(n: int, stat: Callable[[list[int]], float | None], block: int = BLOCK, resamples: int = RESAMPLES, seed: int = SEED) -> tuple[float, float] | None {
    if n < 2 {
        return None;
    }
    rng = random.Random(seed);
    found: list[float] = [];
    for _ in range(resamples) {
        value = stat(block_indices(n, block, rng));
        if value is not None {
            found.append(value);
        }
    }
    if len(found) < resamples // 2 {
        return None;
    }
    found.sort();
    return (percentile(found, 0.025), percentile(found, 0.975));
}

"""The `q` quantile of sorted `values`, interpolated linearly."""
def percentile(values: list[float], q: float) -> float {
    at = q * (len(values) - 1);
    low = math.floor(at);
    high = min(low + 1, len(values) - 1);
    return values[low] + (values[high] - values[low]) * (at - low);
}

"""The mean of `values` and its block-bootstrap interval."""
def mean_interval(values: list[float]) -> tuple[float | None, tuple[float, float] | None] {
    if not values {
        return (None, None);
    }
    def mean_of(idx: list[int]) -> float | None {
        return statistics.fmean(values[i] for i in idx);
    }
    return (statistics.fmean(values), block_interval(len(values), mean_of));
}

"""The interval of Sharpe(a) minus Sharpe(b) over paired daily returns."""
def sharpe_gap_interval(a: list[float], b: list[float]) -> tuple[float, float] | None {
    n = min(len(a), len(b));
    def gap(idx: list[int]) -> float | None {
        x = sharpe([a[i] for i in idx]);
        y = sharpe([b[i] for i in idx]);
        return x - y if x is not None and y is not None else None;
    }
    return block_interval(n, gap);
}

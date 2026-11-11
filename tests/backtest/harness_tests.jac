"""The historical harness's pure pieces (tests/backtest/harness.jac), with no network: a morning
never reads a bar from its own day or later, the hit rate uses the votes' scoring window, the
bootstrap is repeatable, and the screen's new options leave today's screen as it was."""
import random;
import from datetime { date, timedelta }
import from models.research { Stamp }
import from research.alpaca { Bar, BarSeries }
import from research.indicators { summarize }
import from research.screener { Candidate, ScreenConfig, screen, zscores }
import from tests.backtest.harness {
    NewsIndex,
    Prices,
    Universe,
    block_indices,
    block_interval,
    day_hit,
    inputs_on,
    mean_interval,
    morning,
    news_index,
    picked,
    prices_of
}

glob STAMP: Stamp = Stamp(source="test", dataset="test", source_url="", published_at="", fetched_at="");

"""`n` weekday sessions from 2024-01-01."""
def weekdays(n: int) -> list[str] {
    found: list[str] = [];
    day = date(2024, 1, 1);
    while len(found) < n {
        if day.weekday() < 5 {
            found.append(day.isoformat());
        }
        day += timedelta(days=1);
    }
    return found;
}

"""A random walk of bars on `days`, from a fixed seed."""
def walk(days: list[str], seed: int, start: float = 100.0) -> list[Bar] {
    rng = random.Random(seed);
    price = start;
    found: list[Bar] = [];
    for d in days {
        o = price * (1 + rng.uniform(-0.01, 0.01));
        c = o * (1 + rng.uniform(-0.02, 0.02));
        found.append(Bar(day=d, open=o, high=max(o, c) * 1.01, low=min(o, c) * 0.99, close=c, volume=rng.uniform(1e6, 3e6), trades=100, vwap=c));
        price = c;
    }
    return found;
}

def flat(days: list[str], close: float) -> list[Bar] {
    return [Bar(day=d, open=close, high=close, low=close, close=close, volume=1e6, trades=1, vwap=close) for d in days];
}

test "a morning's inputs are the same whatever happens on the day and after" {
    days = weekdays(320);
    bars = walk(days, 1);
    last = days[299];
    seen = inputs_on(prices_of("X", bars), last);
    wild = bars[:300] + [Bar(day=d, open=1e6, high=1e7, low=1.0, close=5e6, volume=1e12, trades=1, vwap=1.0) for d in days[300:]];
    again = inputs_on(prices_of("X", wild), last);
    assert seen is not None and again is not None;
    assert seen.close == bars[299].close and again.close == seen.close;
    assert seen.momentum_20 == again.momentum_20 and seen.rvol_5 == again.rvol_5 and seen.atr_14 == again.atr_14;
}

test "a morning's inputs are what summarize gives on the year of bars through the last session" {
    days = weekdays(400);
    bars = walk(days, 2);
    last = days[379];
    year_ago = (date.fromisoformat(last) - timedelta(days=366)).isoformat();
    window = [b for b in bars if year_ago <= b.day <= last];
    expected = summarize(BarSeries(symbol="X", bars=window, stamp=STAMP));
    got = inputs_on(prices_of("X", bars), last);
    assert got is not None;
    assert got.momentum_20 == expected.momentum_20 and got.momentum_60 == expected.momentum_60;
    assert got.rvol_5 == expected.rvol_5 and got.vol_20 == expected.realized_vol_20;
    assert got.dollar_volume_20 == expected.dollar_volume_20 and got.atr_14 == expected.atr_14;
    assert got.volume_20 == expected.volume_20 and got.sma_200 == expected.sma_200;
}

test "a stock with no bar on the last session has no inputs, so it is untradable that morning" {
    days = weekdays(40);
    bars = walk(days, 3);
    gappy = [b for b in bars if b.day != days[30]];
    assert inputs_on(prices_of("X", gappy), days[30]) is None;
    assert inputs_on(prices_of("X", gappy), days[31]) is not None;
}

test "news counts run from the third session before to 7:30 a.m. on the day" {
    index = news_index([
        ["2024-01-03T23:59:59Z", ["A"]],
        ["2024-01-04T00:00:00Z", ["A", "B"]],
        ["2024-01-09T12:29:59Z", ["A"]],
        ["2024-01-09T12:30:00Z", ["A"]]
    ]);
    assert index.count("A", "2024-01-04T00:00:00Z", "2024-01-09T12:30:00Z") == 2;
    assert index.count("B", "2024-01-04T00:00:00Z", "2024-01-09T12:30:00Z") == 1;
    assert index.count("C", "2024-01-04T00:00:00Z", "2024-01-09T12:30:00Z") == 0;
}

test "the earnings flag reads releases in the five sessions from the day, counted from 0" {
    universe = Universe(members={}, sectors={}, current_sectors={}, companies={"A": "1"}, releases={"1": ["2024-01-05", "2024-03-01"]});
    ahead = ["2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05", "2024-01-08"];
    assert universe.sessions_to_earnings("A", ahead) == 3;
    assert universe.sessions_to_earnings("A", ahead[:3]) is None;
    assert universe.sessions_to_earnings("B", ahead) is None;
}

test "a sector comes from the year's table, then the nearest year's, then today's list" {
    universe = Universe(members={}, sectors={"2018": {"A": "Telecommunication Services"}, "2020": {"A": "Communication Services", "B": "Energy"}}, current_sectors={"C": "Utilities"}, companies={}, releases={});
    assert universe.sector("A", 2018) == "Telecommunication Services";
    assert universe.sector("A", 2021) == "Communication Services";
    assert universe.sector("C", 2016) == "Utilities";
    assert universe.sector("D", 2016) == "Unknown (D)";
}

test "the hit rate scores picks against the rest from the last close before the day to the tenth session" {
    days = weekdays(30);
    day = days[10];
    winners = [Bar(day=d, open=100.0, high=110.0, low=100.0, close=(110.0 if d >= days[19] else 100.0), volume=1e9, trades=1, vwap=100.0) for d in days];
    prices = {"SPY": prices_of("SPY", flat(days, 400.0))};
    candidates: list[Candidate] = [];
    for i in range(20) {
        symbol = f"S{i:02d}";
        prices[symbol] = prices_of(symbol, winners if i < 15 else flat(days, 50.0));
        # The first fifteen have the strongest momentum, so they are the picks.
        candidates.append(Candidate(symbol=symbol, name=symbol, company=symbol, sector=f"sector {i}", tradable=True, momentum_20=1.0 - i * 0.01, momentum_60=0.0, rvol_5=1.0, vol_20=0.2, dollar_volume_20=1e9, news_3=0, earnings_soon=False));
    }
    shortlist = screen(candidates, []);
    assert sorted(picked(shortlist)) == [f"S{i:02d}" for i in range(15)];
    hit = day_hit(day, shortlist, days, prices);
    assert hit is not None and abs(hit.picks_mean - 0.10) < 1e-12 and abs(hit.rest_mean) < 1e-12;
    # Ten sessions counting the day end on days[19]; one session earlier, nothing has moved.
    later = day_hit(days[11], shortlist, days, prices);
    assert later is not None and abs(later.picks_mean - 0.10) < 1e-12;
    assert day_hit(days[25], shortlist, days, prices) is None;
}

test "block resamples are contiguous runs of the block length, cut to the sample size" {
    rng = random.Random(1);
    idx = block_indices(25, 10, rng);
    assert len(idx) == 25;
    assert idx[1] == idx[0] + 1 and idx[9] == idx[0] + 9;
    assert block_indices(3, 10, random.Random(1)) == [0, 1, 2];
}

test "the bootstrap interval is the same on every run and brackets the mean" {
    values = [((i * 37) % 11 - 5) / 100.0 for i in range(200)];
    (mean, first) = mean_interval(values);
    (_, again) = mean_interval(values);
    assert first == again and first is not None;
    assert first[0] < mean < first[1];
    assert block_interval(1, lambda (idx: list[int]) { float(len(idx)); }) is None;
}

test "the screen's new options default to today's screen" {
    config = ScreenConfig();
    assert config.z_clip is None and config.log_terms == [];
    values = [1.0, 2.0, 3.0, 50.0, None];
    assert zscores(values) == zscores(values, None);
    clipped = zscores([0.0] * 30 + [100.0], 3.0);
    assert max(clipped) == 3.0 and zscores([0.0] * 30 + [100.0])[-1] > 5.0;
}

test "log terms and clipping keep one outlier from deciding the shortlist" {
    candidates: list[Candidate] = [];
    for i in range(40) {
        candidates.append(Candidate(symbol=f"S{i:02d}", name="", company=f"S{i:02d}", sector=f"sector {i}", tradable=True, momentum_20=i / 100.0, momentum_60=0.0, rvol_5=1.0, vol_20=0.2, dollar_volume_20=1e9, news_3=(500 if i == 0 else 2), earnings_soon=False));
    }
    plain = screen(candidates, []);
    tamed = screen(candidates, [], ScreenConfig(z_clip=3.0, log_terms=["news_3", "rvol_5"]));
    news_term = [r.terms["news_3"] for r in plain.scores if r.symbol == "S00"][0];
    tamed_term = [r.terms["news_3"] for r in tamed.scores if r.symbol == "S00"][0];
    assert news_term > 6.0 and tamed_term <= 3.0;
    assert picked(plain)[0] == "S00";
    assert picked(tamed)[0] != "S00";
}

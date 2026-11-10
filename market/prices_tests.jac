"""The figures worked out from bars: ratings, votes, beta, and what a stock's year comes to."""
import from market.demo { demo_stamp }
import from market.prices { PriceStats, Signal, beta_of, outside_session, positive_bars, price_stats, rating_label, technical_score, technical_signals }
import from research.alpaca { Bar, BarSeries }

def bar(day: str, close: float, volume: float = 100.0) -> Bar {
    return Bar(day=day, open=close, high=close * 1.01, low=close * 0.99, close=close, volume=volume, trades=1, vwap=close);
}

"""`closes` as bars on made-up consecutive days that end in 2026, so a year boundary is in reach."""
def series(closes: list[float]) -> list[Bar] {
    found: list[Bar] = [];
    for (i, close) in enumerate(closes) {
        offset = len(closes) - 1 - i;
        year = 2026 - offset // 300;
        day_of_year = 299 - offset % 300;
        found.append(bar(f"{year}-{day_of_year // 30 + 1:02d}-{day_of_year % 30 + 1:02d}", close));
    }
    return found;
}

test "a score reads as the same five words at the boundaries" {
    assert rating_label(1.0) == "Strong buy";
    assert rating_label(0.5) == "Strong buy";
    assert rating_label(0.1) == "Buy";
    assert rating_label(0.0) == "Neutral";
    assert rating_label(-0.1) == "Sell";
    assert rating_label(-0.5) == "Strong sell";
    assert rating_label(None) == "";
}

test "the technical score is the mean of the votes present" {
    signals = [Signal(name="a", value=1.0, vote=1), Signal(name="b", value=1.0, vote=-1), Signal(name="c", value=None, vote=None), Signal(name="d", value=1.0, vote=1)];
    assert abs(technical_score(signals) - 1.0 / 3.0) < 1e-9;
    assert technical_score([Signal(name="a", value=None, vote=None)]) is None;
}

test "beta is the slope on the benchmark, and needs enough shared sessions" {
    market = [100.0];
    for i in range(120) {
        market.append(market[-1] * (1.01 if i % 2 else 0.99));
    }
    double = [100.0];
    for i in range(1, len(market)) {
        double.append(double[-1] * (1.0 + 2.0 * (market[i] / market[i - 1] - 1.0)));
    }
    stock = series(double);
    benchmark = series(market);
    assert abs(beta_of(stock, benchmark) - 2.0) < 1e-6;
    assert beta_of(stock[-30:], benchmark[-30:]) is None;
    flat = series([100.0] * 121);
    assert beta_of(stock, flat) is None;
}

test "a stock's stats reach back by session and to last year's close" {
    closes = [100.0 + i for i in range(320)];
    bars = series(closes);
    stats = price_stats(BarSeries(stamp=demo_stamp("2026-11-05"), symbol="X", bars=bars));
    assert stats.anchors["1w"] == closes[-6];
    assert stats.anchors["1y"] == closes[-253];
    assert stats.anchors["ytd"] == [b for b in bars if b.day[:4] < bars[-1].day[:4]][-1].close;
    assert stats.high_52w == closes[-1] * 1.01;
    assert stats.low_52w == closes[-252] * 0.99;
    assert stats.beta is None;
}

test "a stock's stats keep its last two closes, and a close below zero is no price" {
    stats = price_stats(BarSeries(stamp=demo_stamp("2026-11-05"), symbol="X", bars=series([10.0, 11.0, 12.0])));
    assert stats.last_close == 12.0 and stats.prior_close == 11.0;
    assert [b.close for b in positive_bars(series([-5.0, 0.0, 2.0]))] == [2.0];
}

test "a young stock has no anchor it cannot reach" {
    stats = price_stats(BarSeries(stamp=demo_stamp("2026-11-05"), symbol="X", bars=series([10.0 + i for i in range(30)])));
    assert "1w" in stats.anchors and "1m" in stats.anchors and "3m" not in stats.anchors and "1y" not in stats.anchors;
}

test "indicators vote with the price, and an absent one abstains" {
    stats = PriceStats(symbol="X", day="2026-11-05", sma_20=90.0, sma_50=110.0, sma_200=None, rsi_14=75.0, macd_hist=-1.0, momentum_20=0.2);
    votes = {s.name: s.vote for s in technical_signals(100.0, stats)};
    assert votes["Price vs. 20-day average"] == 1;
    assert votes["Price vs. 50-day average"] == -1;
    assert votes["Price vs. 200-day average"] is None;
    assert votes["RSI (14)"] == -1;
    assert votes["MACD histogram"] == -1;
    assert votes["20-session momentum"] == 1;
}

test "a trade is outside the session by New York's clock" {
    assert not outside_session("2026-11-05T15:00:00Z");
    assert outside_session("2026-11-05T22:00:00Z");
    assert outside_session("2026-11-05T13:00:00Z");
    assert not outside_session("");
}

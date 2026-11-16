"""The crypto screener's data (market/coins.jac): a year of daily bars reduced to a row, over
calendar days, and an invented market for demo servers."""
import math;
import from datetime { date, timedelta }
import from market.coins { CoinListing, CoinPrice, coin_beta, coin_name, coin_row, coin_rows, coin_stats, coin_volatility }
import from market.demo { DEMO_COINS, demo_stamp, demo_state }
import from research.alpaca { Bar, BarSeries }

def number(value: float | str | None) -> float {
    assert isinstance(value, float), value;
    return value;
}

"""`closes`, one a calendar day, ending on 2026-11-14."""
def series(symbol: str, closes: list[float]) -> BarSeries {
    end = date(2026, 11, 14);
    bars = [
        Bar(day=(end - timedelta(days=len(closes) - 1 - i)).isoformat(), open=c, high=c * 1.01, low=c * 0.99, close=c, volume=10.0, trades=0, vwap=c)
        for (i, c) in enumerate(closes)
    ];
    return BarSeries(symbol=symbol, bars=bars, stamp=demo_stamp("2026-11-14"));
}

test "a coin's periods are calendar days, and its row measures from the latest trade" {
    closes = [100.0 + i for i in range(400)];
    stats = coin_stats(series("ETH/USD", closes));
    assert stats.day == "2026-11-14" and stats.last_close == 499.0;
    assert stats.anchors["1w"] == 492.0 and stats.anchors["1y"] == 134.0, stats.anchors;
    assert stats.high_52w == 499.0 * 1.01 and stats.low_52w == 135.0 * 0.99;
    row = coin_row(CoinListing(symbol="ETH/USD", name="Ethereum"), CoinPrice(price=549.0, at="2026-11-15T12:00:00Z"), stats);
    assert row["price"] == 549.0 and row["kind"] == "Crypto";
    assert math.isclose(number(row["change_pct"]), 549.0 / 499.0 - 1.0);
    assert math.isclose(number(row["perf_1w"]), 549.0 / 492.0 - 1.0);
    assert row["dollar_volume"] is not None and row["rsi_14"] == 100.0;
}

test "a coin without a trade or bars still has a row, with what it lacks left empty" {
    row = coin_row(CoinListing(symbol="NEW/USD", name="New"), None, None);
    assert row["price"] is None and row["perf_1y"] is None and row["change_pct"] is None;
    stats = coin_stats(series("NEW/USD", [5.0, 6.0]));
    row = coin_row(CoinListing(symbol="NEW/USD", name="New"), None, stats);
    assert row["price"] == 6.0 and row["perf_1w"] is None and row["volatility"] is None;
}

test "volatility is annualized over a 365-day year, and beta is measured against BTC" {
    steady = [100.0 * (1.01 if i % 2 else 0.99) ** 1 for i in range(40)];
    found = coin_volatility(steady);
    assert found is not None and found > 0.3;
    btc = series("BTC/USD", [100.0 * (1.0 + 0.02 * ((i % 3) - 1)) for i in range(60)]);
    twice = series("SOL/USD", [100.0 * (1.0 + 0.04 * ((i % 3) - 1)) for i in range(60)]);
    beta = coin_beta(twice.bars, btc.bars);
    assert beta is not None and beta > 1.5, beta;
    assert coin_stats(btc).beta == 1.0;
    assert coin_beta(twice.bars[:10], btc.bars) is None;
}

test "a pair's name drops the quote currency, and the most traded coin comes first" {
    assert coin_name("Bitcoin / US Dollar", "BTC/USD") == "Bitcoin";
    assert coin_name("", "BTC/USD") == "BTC";
    listings = {"A/USD": CoinListing(symbol="A/USD", name="A"), "B/USD": CoinListing(symbol="B/USD", name="B")};
    quiet = coin_stats(series("A/USD", [1.0] * 40));
    busy = coin_stats(series("B/USD", [100.0] * 40));
    rows = coin_rows(listings, {}, {"A/USD": quiet, "B/USD": busy});
    assert [r["symbol"] for r in rows] == ["B/USD", "A/USD"];
}

test "a demo server invents every demo coin, with a year of bars and a price" {
    state = demo_state(date(2026, 11, 15));
    assert sorted(state.coins) == sorted(c.symbol for c in DEMO_COINS);
    btc = state.coin_stats["BTC/USD"];
    assert btc.day == "2026-11-14" and btc.beta == 1.0 and btc.anchors.get("1y");
    assert len(state.coin_bars("ETH/USD")) >= 365;
    assert all(p.price > 0.0 for p in state.coin_prices.values());
    # The same day invents the same market.
    again = demo_state(date(2026, 11, 15));
    assert again.coin_prices["SOL/USD"].price == state.coin_prices["SOL/USD"].price;
}

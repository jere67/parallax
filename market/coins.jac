"""The crypto screener's data: every pair Alpaca trades against the dollar, with its latest price and
what a year of daily bars says about it.

Crypto trades every day, so its periods are calendar days (a week is 7 bars, a year 365) and its
volatility is annualized over 365 days. A daily bar is a UTC day and is final once that day ends
(research/crypto.jac), so the bars are read once a UTC day; the price is the latest trade, read
every few minutes. Coins are compared with BTC/USD, as stocks are with SPY.

The rows use the stock rows' field names (market/rows.jac) where they mean the same thing, so the
screener's filters, sorts, and formats work on both.
"""
import math;
import statistics;
import from research.alpaca { Bar, BarSeries, LatestTrade }
import from research.crypto { CRYPTO_BENCHMARK, CryptoAsset }
import from research.indicators { dollar_volume, rsi, sma }

glob COIN_PERIODS: dict[str, int] = {"1w": 7, "1m": 30, "3m": 90, "6m": 182, "1y": 365};
glob DAYS_PER_YEAR: float = 365.0;
glob VOLATILITY_DAYS: int = 30;
glob BETA_DAYS: int = 365;
# A page's chart shows a year; the bars are kept a little deeper so the year's first close has one before it.
glob KEPT_BARS: int = 400;

"""A pair as Alpaca lists it."""
obj CoinListing {
    has symbol: str,
        name: str,
        tradable: bool = True,
        min_order_size: float = 0.0,
        min_trade_increment: float = 0.0,
        price_increment: float = 0.0;
}

"""The latest trade's price and when it happened (UTC, ISO)."""
obj CoinPrice {
    has price: float,
        at: str;
}

"""What a coin's daily bars say, as of the close of UTC day `day`. `anchors` holds the close a
period ago for each period in COIN_PERIODS."""
obj CoinStats {
    has symbol: str,
        day: str,
        anchors: dict[str, float] = {},
        last_close: float | None = None,
        high_52w: float | None = None,
        low_52w: float | None = None,
        sma_20: float | None = None,
        sma_50: float | None = None,
        sma_200: float | None = None,
        rsi_14: float | None = None,
        volatility: float | None = None,
        dollar_volume: float | None = None,
        volume: float | None = None,
        beta: float | None = None;
}

def listing_of(asset: CryptoAsset) -> CoinListing {
    return CoinListing(
        symbol=asset.symbol,
        name=coin_name(asset.name, asset.symbol),
        tradable=asset.tradable,
        min_order_size=asset.min_order_size,
        min_trade_increment=asset.min_trade_increment,
        price_increment=asset.price_increment
    );
}

"""The coin's own name: Alpaca names a pair "Bitcoin / US Dollar"."""
def coin_name(name: str, symbol: str) -> str {
    base = name.split(" / ")[0].strip() if " / " in name else name.strip();
    return base or symbol.split("/")[0];
}

"""Annualized standard deviation of the last n daily log returns, over a 365-day year."""
def coin_volatility(closes: list[float], n: int = VOLATILITY_DAYS) -> float | None {
    if len(closes) <= n or min(closes[-1 - n:]) <= 0.0 {
        return None;
    }
    window = closes[-1 - n:];
    returns = [math.log(b / a) for (a, b) in zip(window, window[1:])];
    return statistics.stdev(returns) * math.sqrt(DAYS_PER_YEAR);
}

"""The slope of the coin's daily returns on the benchmark's, over the days both have."""
def coin_beta(coin: list[Bar], benchmark: list[Bar], n: int = BETA_DAYS) -> float | None {
    bench = {b.day: b.close for b in benchmark};
    paired = [(b.close, bench[b.day]) for b in coin[-(n + 1):] if b.day in bench];
    if len(paired) < 31 {
        return None;
    }
    mine = [b / a - 1.0 for ((a, _), (b, _)) in zip(paired, paired[1:]) if a > 0.0];
    theirs = [y / x - 1.0 for ((_, x), (_, y)) in zip(paired, paired[1:]) if x > 0.0];
    if len(mine) != len(theirs) or len(theirs) < 30 {
        return None;
    }
    spread = statistics.pvariance(theirs);
    if spread <= 0.0 {
        return None;
    }
    (mx, my) = (statistics.fmean(theirs), statistics.fmean(mine));
    return sum((x - mx) * (y - my) for (x, y) in zip(theirs, mine)) / len(theirs) / spread;
}

"""What `series`'s bars say, against `benchmark`'s. Bars must be oldest first."""
def coin_stats(series: BarSeries, benchmark: BarSeries | None = None) -> CoinStats {
    bars = [b for b in series.bars if b.close > 0.0];
    closes = [b.close for b in bars];
    year = bars[-365:];
    anchors: dict[str, float] = {};
    for (name, days) in COIN_PERIODS.items() {
        if len(bars) > days {
            anchors[name] = bars[-1 - days].close;
        }
    }
    return CoinStats(
        symbol=series.symbol,
        day=bars[-1].day if bars else "",
        anchors=anchors,
        last_close=closes[-1] if closes else None,
        high_52w=max(b.high for b in year) if year else None,
        low_52w=min(b.low for b in year) if year else None,
        sma_20=sma(closes, 20),
        sma_50=sma(closes, 50),
        sma_200=sma(closes, 200),
        rsi_14=rsi(closes) if len(closes) > 15 else None,
        volatility=coin_volatility(closes),
        dollar_volume=dollar_volume(closes, [b.volume for b in bars], VOLATILITY_DAYS),
        volume=bars[-1].volume if bars else None,
        beta=1.0 if series.symbol == CRYPTO_BENCHMARK else coin_beta(bars, benchmark.bars if benchmark else [])
    );
}

"""A bar as kept on disk: [day, open, high, low, close, volume]."""
def kept_bar(b: Bar) -> list[float | str] {
    return [b.day, b.open, b.high, b.low, b.close, b.volume];
}

def ratio(a: float | None, b: float | None) -> float | None {
    if a is None or b is None or b <= 0.0 or not math.isfinite(a) {
        return None;
    }
    return a / b - 1.0;
}

"""A coin's flat row. The price is the latest trade's, or the last close without one; "today" is
since the last final close, at 00:00 UTC."""
def coin_row(listing: CoinListing, price: CoinPrice | None, stats: CoinStats | None) -> dict[str, float | str | None] {
    last = stats.last_close if stats else None;
    now: float | None = price.price if price else last;
    anchors = stats.anchors if stats else {};
    row: dict[str, float | str | None] = {
        "symbol": listing.symbol,
        "name": listing.name,
        "kind": "Crypto",
        "price": now,
        "price_at": price.at if price else (stats.day if stats else None),
        "change": now - last if now is not None and last is not None else None,
        "change_pct": ratio(now, last),
        "volume": stats.volume if stats else None,
        "dollar_volume": stats.dollar_volume if stats else None,
        "high_52w": stats.high_52w if stats else None,
        "low_52w": stats.low_52w if stats else None,
        "from_high_pct": ratio(now, stats.high_52w if stats else None),
        "from_low_pct": ratio(now, stats.low_52w if stats else None),
        "volatility": stats.volatility if stats else None,
        "rsi_14": stats.rsi_14 if stats else None,
        "sma_20_pct": ratio(now, stats.sma_20 if stats else None),
        "sma_50_pct": ratio(now, stats.sma_50 if stats else None),
        "sma_200_pct": ratio(now, stats.sma_200 if stats else None),
        "beta": stats.beta if stats else None,
        "tradable": "Yes" if listing.tradable else "No"
    };
    for name in COIN_PERIODS {
        row[f"perf_{name}"] = ratio(now, anchors.get(name));
    }
    return row;
}

"""Every coin's row, most traded first."""
def coin_rows(listings: dict[str, CoinListing], prices: dict[str, CoinPrice], stats: dict[str, CoinStats]) -> list[dict[str, float | str | None]] {
    rows = [coin_row(l, prices.get(s), stats.get(s)) for (s, l) in listings.items()];
    def traded(r: dict[str, float | str | None]) -> float {
        v = r.get("dollar_volume");
        return float(v) if isinstance(v, (int, float)) else -1.0;
    }
    rows.sort(key=lambda (r: dict[str, float | str | None]) { (0.0 - traded(r), str(r["symbol"])); });
    return rows;
}

def price_of(trade: LatestTrade) -> CoinPrice {
    return CoinPrice(price=trade.price, at=trade.at);
}

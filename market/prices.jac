"""What the market pages know from prices: the delayed quote for a whole market in a few
requests, and each stock's year of daily bars reduced to a few numbers.

The quote comes from Alpaca's snapshots on the delayed SIP feed, which the free plan may read
for every U.S. exchange (checked 2026-11-06). The regular session's price is its daily bar's
close, and a later trade is the extended-hours price.

Perf anchors are the closes a period ago rather than the returns, so a row's performance
follows the live price between the nightly bar refreshes.
"""
import json;
import math;
import statistics;
import from datetime { time }
import from research.alpaca { Bar, BarSeries, MARKET_TZ, alpaca_data_client }
import from research.collector { RunBudget, SourceClient, parse_utc }
import from research.indicators { Technicals, summarize }
import from research.sources { DATASETS }

glob SNAPSHOT_SYMBOLS: int = 600;
glob SESSION_OPEN: time = time(9, 30);
glob SESSION_CLOSE: time = time(16, 0);
glob BETA_SESSIONS: int = 252;
glob AVERAGE_VOLUME_SESSIONS: int = 30;
# Sessions back for each performance period; the year to date is from the last close of last year.
glob PERIODS: dict[str, int] = {"1w": 5, "1m": 21, "3m": 63, "6m": 126, "1y": 252};
# How far a label sits from neutral on the -1 to 1 scale.
glob STRONG: float = 0.5;
glob LEAN: float = 0.1;
glob RATING_LABELS: list[str] = ["Strong sell", "Sell", "Neutral", "Buy", "Strong buy"];

"""One stock's delayed quote. `price` is the latest regular session's, `ext_price` a later trade's."""
obj Quote {
    has symbol: str,
        day: str,
        price: float,
        prev_close: float | None = None,
        open: float | None = None,
        high: float | None = None,
        low: float | None = None,
        volume: float | None = None,
        ext_price: float | None = None,
        trade_at: str = "";
}

"""One stock's reduced bars, as of the session `day`."""
obj PriceStats {
    has symbol: str,
        day: str,
        anchors: dict[str, float] = {},
        average_volume: float | None = None,
        high_52w: float | None = None,
        low_52w: float | None = None,
        sma_20: float | None = None,
        sma_50: float | None = None,
        sma_200: float | None = None,
        rsi_14: float | None = None,
        macd_hist: float | None = None,
        atr_pct: float | None = None,
        volatility: float | None = None,
        momentum_20: float | None = None,
        beta: float | None = None,
        last_close: float | None = None,
        prior_close: float | None = None;
}

"""One indicator's vote: 1 buy, -1 sell, 0 neutral, or None without the data."""
obj Signal {
    has name: str,
        value: float | None,
        vote: int | None;
}

"""The delayed quote for each symbol Alpaca has; a symbol it omits is simply not returned."""
def snapshots(symbols: list[str], budget: RunBudget, client: SourceClient | None = None) -> dict[str, Quote] {
    data = client or alpaca_data_client();
    found: dict[str, Quote] = {};
    wanted = sorted(set(symbols));
    for i in range(0, len(wanted), SNAPSHOT_SYMBOLS) {
        fetched = data.get(
            DATASETS["alpaca.market_snapshots"],
            "/v2/stocks/snapshots",
            budget,
            params={"symbols": ",".join(wanted[i:i + SNAPSHOT_SYMBOLS]), "feed": "delayed_sip"},
            check=_check_object
        );
        for (symbol, row) in json.loads(fetched.body).items() {
            quote = quote_of(symbol, row);
            if quote is not None {
                found[symbol] = quote;
            }
        }
    }
    return found;
}

"""A snapshot as a quote, or None without a daily bar. A trade outside the regular session is
the extended-hours price; the daily bar leaves those out."""
def quote_of(symbol: str, row: dict[str, dict[str, any] | None]) -> Quote | None {
    bar = row.get("dailyBar") or row.get("prevDailyBar");
    if not bar {
        return None;
    }
    prev = row.get("prevDailyBar") if row.get("dailyBar") else None;
    trade = row.get("latestTrade") or {};
    close = float(bar["c"]);
    last = trade.get("p");
    return Quote(
        symbol=symbol,
        day=str(bar["t"])[:10],
        price=close,
        prev_close=float(prev["c"]) if prev else None,
        open=float(bar["o"]),
        high=float(bar["h"]),
        low=float(bar["l"]),
        volume=float(bar["v"]),
        ext_price=float(last) if last is not None and outside_session(str(trade.get("t") or "")) else None,
        trade_at=str(trade.get("t") or "")
    );
}

"""Whether a UTC timestamp falls outside 9:30 a.m. to 4 p.m. New York time."""
def outside_session(at: str) -> bool {
    if len(at) < 16 {
        return False;
    }
    local = parse_utc(at[:19] + "+00:00").astimezone(MARKET_TZ).time();
    return not (SESSION_OPEN <= local < SESSION_CLOSE);
}

"""The bars that can be prices: adjusting an old close for dividends larger than it leaves it
below zero, which no return or range can be measured from."""
def positive_bars(bars: list[Bar]) -> list[Bar] {
    return [b for b in bars if b.close > 0.0 and b.low > 0.0];
}

"""A year of daily bars reduced to what the market pages show. `spy` gives beta."""
def price_stats(series: BarSeries, spy: BarSeries | None = None) -> PriceStats {
    t: Technicals = summarize(series, spy);
    bars = series.bars;
    last = bars[-1];
    year = bars[-BETA_SESSIONS:];
    anchors: dict[str, float] = {};
    for (name, sessions) in PERIODS.items() {
        if len(bars) > sessions {
            anchors[name] = bars[-1 - sessions].close;
        }
    }
    before_year = [b for b in bars if b.day[:4] < last.day[:4]];
    if before_year {
        anchors["ytd"] = before_year[-1].close;
    }
    return PriceStats(
        symbol=series.symbol,
        day=last.day,
        anchors=anchors,
        average_volume=statistics.fmean(b.volume for b in bars[-AVERAGE_VOLUME_SESSIONS:]),
        high_52w=max(b.high for b in year),
        low_52w=min(b.low for b in year),
        sma_20=t.sma_20,
        sma_50=t.sma_50,
        sma_200=t.sma_200,
        rsi_14=t.rsi_14,
        macd_hist=t.macd_hist,
        atr_pct=t.atr_pct,
        volatility=t.realized_vol_20,
        momentum_20=t.momentum_20,
        beta=beta_of(bars, spy.bars) if spy else None,
        last_close=last.close,
        prior_close=bars[-2].close if len(bars) > 1 else None
    );
}

"""The slope of the stock's daily returns on the benchmark's over the last year, matched by
session, or None with under 60 shared sessions or a flat benchmark."""
def beta_of(stock: list[Bar], benchmark: list[Bar]) -> float | None {
    closes = {b.day: b.close for b in benchmark[-BETA_SESSIONS - 1:]};
    pairs: list[tuple[float, float]] = [];
    recent = stock[-BETA_SESSIONS - 1:];
    for (before, bar) in zip(recent, recent[1:]) {
        if before.close > 0 and before.day in closes and bar.day in closes and closes[before.day] > 0 {
            pairs.append((bar.close / before.close - 1.0, closes[bar.day] / closes[before.day] - 1.0));
        }
    }
    if len(pairs) < 60 {
        return None;
    }
    market = [p[1] for p in pairs];
    spread = statistics.pvariance(market);
    if spread <= 0 {
        return None;
    }
    mean_stock = statistics.fmean(p[0] for p in pairs);
    mean_market = statistics.fmean(market);
    slope = sum((p[0] - mean_stock) * (p[1] - mean_market) for p in pairs) / len(pairs) / spread;
    return slope if math.isfinite(slope) else None;
}

"""Each indicator's vote at `price`: above a moving average is a buy, an RSI under 30 a buy and
over 70 a sell, MACD above its signal a buy, and a month's momentum follows its sign."""
def technical_signals(price: float, stats: PriceStats) -> list[Signal] {
    def above(average: float | None) -> int | None {
        return None if average is None else (1 if price > average else -1);
    }
    rsi = stats.rsi_14;
    return [
        Signal(name="Price vs. 20-day average", value=stats.sma_20, vote=above(stats.sma_20)),
        Signal(name="Price vs. 50-day average", value=stats.sma_50, vote=above(stats.sma_50)),
        Signal(name="Price vs. 200-day average", value=stats.sma_200, vote=above(stats.sma_200)),
        Signal(name="RSI (14)", value=rsi, vote=None if rsi is None else (1 if rsi < 30 else (-1 if rsi > 70 else 0))),
        Signal(name="MACD histogram", value=stats.macd_hist, vote=None if stats.macd_hist is None else (1 if stats.macd_hist > 0 else -1)),
        Signal(name="20-session momentum", value=stats.momentum_20, vote=None if stats.momentum_20 is None else (1 if stats.momentum_20 > 0 else -1))
    ];
}

"""The mean of the votes present, from -1 to 1, or None with no votes."""
def technical_score(signals: list[Signal]) -> float | None {
    votes = [s.vote for s in signals if s.vote is not None];
    return float(sum(votes)) / len(votes) if votes else None;
}

"""A -1 to 1 score as words, the same scale for technicals and analysts."""
def rating_label(score: float | None) -> str {
    if score is None {
        return "";
    }
    if score >= STRONG {
        return RATING_LABELS[4];
    }
    if score >= LEAN {
        return RATING_LABELS[3];
    }
    if score > 0 - LEAN {
        return RATING_LABELS[2];
    }
    return RATING_LABELS[1] if score > 0 - STRONG else RATING_LABELS[0];
}

def _check_object(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, dict) and "message" not in parsed else f"not a snapshot table: {body[:200]}";
}

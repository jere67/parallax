"""Alpaca crypto data: the pairs an account can trade, their daily bars and latest trades, and which
pairs a run covers.

Crypto trades around the clock, so a daily bar is a UTC day, and a day's bar is final once that UTC
day has ended. Alpaca writes pairs with a slash ("BTC/USD") in orders, assets, and market data, but
without one in positions ("BTCUSD") and in news ("BTCUSD"); `pair_of` and `news_symbol` convert.
No stock symbol holds a slash, so `is_crypto` tells the two apart everywhere.

Only pairs quoted in U.S. dollars are covered, so every price, size, and P&L is in dollars like a
stock's. Keys go in headers, which the cache and recorded fixtures never keep.
"""
import json;
import math;
import from datetime { date, datetime, timedelta, timezone }
import from urllib.parse { urlencode }
import from models.research { Stamped }
import from research.alpaca { Bar, BarSeries, LatestTrade, alpaca_data_client, alpaca_trading_client }
import from research.collector { Fetched, RunBudget, SourceClient, parse_utc, utc_now }
import from research.indicators { dollar_volume }
import from research.sources { DATASETS, SOURCES }

glob CRYPTO_CLASS: str = "crypto";
glob CRYPTO_SECTOR: str = "Crypto";
glob QUOTE: str = "USD";
# The pair other coins are compared with, as SPY is for stocks.
glob CRYPTO_BENCHMARK: str = "BTC/USD";
glob BARS_PER_PAGE: int = 10000;
glob SYMBOLS_PER_REQUEST: int = 100;
# A pair needs about three months of bars before its indicators mean anything.
glob MIN_BARS: int = 60;

"""True for a crypto pair ("BTC/USD") and False for a stock or an option."""
def is_crypto(symbol: str) -> bool {
    return "/" in symbol;
}

"""The pair a crypto position names: Alpaca reports "BTCUSD" for "BTC/USD". Anything else comes
back unchanged."""
def pair_of(symbol: str) -> str {
    if is_crypto(symbol) or not symbol.endswith(QUOTE) or len(symbol) <= len(QUOTE) {
        return symbol;
    }
    return f"{symbol[:-len(QUOTE)]}/{QUOTE}";
}

"""How Alpaca's news API names a pair: "BTCUSD"."""
def news_symbol(symbol: str) -> str {
    return symbol.replace("/", "");
}

"""A crypto pair as Alpaca's asset list has it. Quantities may be fractional, down to
`min_trade_increment`; an order must be at least `min_order_size` coins, and its limit price a
multiple of `price_increment`."""
obj CryptoAsset(Stamped) {
    has symbol: str,
        name: str,
        tradable: bool;
    has min_order_size: float = 0.0,
        min_trade_increment: float = 0.0,
        price_increment: float = 0.0;
}

"""Every active crypto pair quoted in dollars, by pair."""
def crypto_assets(budget: RunBudget, client: SourceClient | None = None) -> dict[str, CryptoAsset] {
    fetched = (client or alpaca_trading_client()).get(
        DATASETS["alpaca.crypto_assets"],
        "/v2/assets",
        budget,
        params={"status": "active", "asset_class": CRYPTO_CLASS},
        check=_check_list
    );
    found: dict[str, CryptoAsset] = {};
    for row in json.loads(fetched.body) {
        symbol = str(row.get("symbol") or "");
        if not symbol.endswith(f"/{QUOTE}") {
            continue;
        }
        found[symbol] = CryptoAsset(
            symbol=symbol,
            name=str(row.get("name") or symbol),
            tradable=bool(row.get("tradable")),
            min_order_size=_number(row.get("min_order_size")),
            min_trade_increment=_number(row.get("min_trade_increment")),
            price_increment=_number(row.get("price_increment")),
            stamp=fetched.snapshot()
        );
    }
    return found;
}

"""The last UTC day whose crypto bar is final at `now`: yesterday in UTC."""
def last_final_day(now: datetime | None = None) -> str {
    return ((now or utc_now()).astimezone(timezone.utc).date() - timedelta(days=1)).isoformat();
}

"""Daily bars (UTC days) from `start` through `end` (ISO dates, inclusive) for each pair, and a gap
for each pair with none. `end` must be a final day (`last_final_day`), so its bars are cached for
good. Each series is stamped when its newest bar's day ended."""
def crypto_bars(
    symbols: list[str],
    start: str,
    end: str,
    budget: RunBudget,
    client: SourceClient | None = None
) -> tuple[list[BarSeries], list[str]] {
    if end > last_final_day() {
        raise ValueError(f"end {end} is not a final crypto day; the last one is {last_final_day()}");
    }
    data = client or alpaca_data_client();
    dataset = DATASETS["alpaca.crypto_bars"];
    query = {"timeframe": "1Day", "start": f"{start}T00:00:00Z", "end": f"{end}T00:00:00Z"};
    wanted = sorted(set(symbols));
    bars: dict[str, list[Bar]] = {};
    pages: dict[str, Fetched] = {};
    for i in range(0, len(wanted), SYMBOLS_PER_REQUEST) {
        chunk = wanted[i:i + SYMBOLS_PER_REQUEST];
        token = "";
        while True {
            params: dict[str, str | int | float] = {**query, "symbols": ",".join(chunk), "limit": BARS_PER_PAGE};
            if token {
                params["page_token"] = token;
            }
            fetched = data.get(dataset, "/v1beta3/crypto/us/bars", budget, params=params, day=end, check=_check_keyed("bars"));
            page = json.loads(fetched.body);
            for (symbol, rows) in (page.get("bars") or {}).items() {
                bars.setdefault(symbol, []).extend(_bar(row) for row in rows);
                pages.setdefault(symbol, fetched);
            }
            token = page.get("next_page_token") or "";
            if not token {
                break;
            }
        }
    }
    found: list[BarSeries] = [];
    gaps: list[str] = [];
    for symbol in wanted {
        rows = [b for b in bars.get(symbol, []) if b.close > 0.0];
        if not rows {
            gaps.append(f"alpaca.crypto_bars: no daily bars for {symbol} from {start} to {end}");
            continue;
        }
        series = sorted(rows, key=lambda (b: Bar) { b.day; });
        closed = (date.fromisoformat(series[-1].day) + timedelta(days=1)).isoformat() + "T00:00:00+00:00";
        cite = SOURCES["alpaca_data"].base_url + "/v1beta3/crypto/us/bars?" + urlencode({**query, "symbols": symbol});
        found.append(BarSeries(symbol=symbol, bars=series, stamp=pages[symbol].stamp(closed, source_url=cite)));
    }
    return (found, gaps);
}

"""The latest trade for each pair, and a gap for each pair without one."""
def crypto_latest_trades(symbols: list[str], budget: RunBudget, client: SourceClient | None = None) -> tuple[list[LatestTrade], list[str]] {
    wanted = sorted(set(s for s in symbols if is_crypto(s)));
    if not wanted {
        return ([], []);
    }
    data = client or alpaca_data_client();
    trades: list[LatestTrade] = [];
    gaps: list[str] = [];
    for i in range(0, len(wanted), SYMBOLS_PER_REQUEST) {
        chunk = wanted[i:i + SYMBOLS_PER_REQUEST];
        fetched = data.get(
            DATASETS["alpaca.crypto_trade"],
            "/v1beta3/crypto/us/latest/trades",
            budget,
            params={"symbols": ",".join(chunk)},
            check=_check_keyed("trades")
        );
        found: dict[str, dict[str, str | float]] = json.loads(fetched.body).get("trades") or {};
        for symbol in chunk {
            row = found.get(symbol);
            if not row {
                gaps.append(f"alpaca.crypto_trade: no trade for {symbol}");
                continue;
            }
            cite = SOURCES["alpaca_data"].base_url + "/v1beta3/crypto/us/latest/trades?" + urlencode({"symbols": symbol});
            trades.append(LatestTrade(
                symbol=symbol,
                price=float(row["p"]),
                size=float(row.get("s") or 0.0),
                at=str(row["t"]),
                exchange="crypto",
                stamp=fetched.stamp(str(row["t"]), source_url=cite)
            ));
        }
    }
    return (trades, gaps);
}

"""The pairs a run covers: every tradable pair in `assets` with at least MIN_BARS bars in
`series`, ranked by 20-day dollar volume, the top `size`, then every pair in `held` the ranking
left out, since an open position is always reviewed."""
def crypto_universe(assets: dict[str, CryptoAsset], series: dict[str, BarSeries], size: int, held: list[str]) -> list[str] {
    ranked: list[tuple[float, str]] = [];
    for (symbol, asset) in assets.items() {
        found = series.get(symbol);
        if not asset.tradable or found is None or len(found.bars) < MIN_BARS {
            continue;
        }
        traded = dollar_volume([b.close for b in found.bars], [b.volume for b in found.bars]);
        if traded is not None and math.isfinite(traded) and traded > 0.0 {
            ranked.append((traded, symbol));
        }
    }
    ranked.sort(key=lambda (r: tuple[float, str]) { (-r[0], r[1]); });
    picked = [s for (_, s) in ranked[:max(0, size)]];
    return picked + sorted(s for s in set(held) if s not in picked);
}

def _bar(row: dict[str, float | int | str]) -> Bar {
    return Bar(
        day=parse_utc(str(row["t"])).date().isoformat(),
        open=float(row["o"]),
        high=float(row["h"]),
        low=float(row["l"]),
        close=float(row["c"]),
        volume=float(row["v"]),
        trades=int(row.get("n") or 0),
        vwap=float(row.get("vw") or 0.0)
    );
}

def _number(value: object) -> float {
    try {
        found = float(str(value)) if value is not None and str(value) != "" else 0.0;
    } except ValueError {
        return 0.0;
    }
    return found if math.isfinite(found) else 0.0;
}

def _check_keyed(key: str) -> Callable[[str], str] {
    def check(body: str) -> str {
        try {
            parsed = json.loads(body);
        } except ValueError {
            return f"not JSON: {body[:200]}";
        }
        return "" if isinstance(parsed, dict) and key in parsed else f"no {key!r} in {body[:200]}";
    }
    return check;
}

def _check_list(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, list) else f"expected a list: {body[:200]}";
}

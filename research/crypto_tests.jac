"""Crypto pairs (research/crypto.jac): symbol conversions, the last final day, and which coins a
run covers."""
import from datetime { datetime, timezone }
import from research.alpaca { Bar, BarSeries }
import from research.crypto { CryptoAsset, crypto_universe, is_crypto, last_final_day, news_symbol, pair_of }
import from models.research { Stamp }

glob STAMP: Stamp = Stamp(source="alpaca_data", dataset="alpaca.crypto_bars", source_url="https://data.alpaca.markets/", published_at="2026-11-14T00:00:00+00:00", fetched_at="2026-11-14T12:00:00+00:00");

def series(symbol: str, close: float, volume: float, days: int = 80) -> BarSeries {
    bars = [Bar(day=f"2026-{8 + i // 28:02d}-{1 + i % 28:02d}", open=close, high=close, low=close, close=close, volume=volume, trades=1, vwap=close) for i in range(days)];
    return BarSeries(symbol=symbol, bars=bars, stamp=STAMP);
}

def pair(symbol: str, tradable: bool = True) -> CryptoAsset {
    return CryptoAsset(symbol=symbol, name=symbol, tradable=tradable, stamp=STAMP);
}

test "a pair holds a slash, positions and news drop it, and pair_of puts it back" {
    assert is_crypto("BTC/USD") and not is_crypto("AAPL");
    assert pair_of("BTCUSD") == "BTC/USD" and pair_of("BTC/USD") == "BTC/USD" and pair_of("AAPL") == "AAPL";
    assert news_symbol("ETH/USD") == "ETHUSD";
}

test "a day's crypto bar is final once its UTC day has ended" {
    assert last_final_day(datetime(2026, 11, 14, 12, 30, tzinfo=timezone.utc)) == "2026-11-13";
    assert last_final_day(datetime(2026, 11, 15, 0, 30, tzinfo=timezone.utc)) == "2026-11-14";
}

test "a run covers the most traded tradable pairs with enough history, then every held pair" {
    assets = {s: pair(s) for s in ["BTC/USD", "ETH/USD", "SOL/USD", "NEW/USD"]};
    assets["DEAD/USD"] = pair("DEAD/USD", tradable=False);
    bars = {
        "BTC/USD": series("BTC/USD", 90000.0, 100.0),
        "ETH/USD": series("ETH/USD", 3000.0, 1000.0),
        "SOL/USD": series("SOL/USD", 150.0, 1000.0),
        "NEW/USD": series("NEW/USD", 1.0, 1e12, days=20),
        "DEAD/USD": series("DEAD/USD", 1.0, 1e12)
    };
    # Dollar volume: BTC 9M, ETH 3M, SOL 150k; NEW lacks history and DEAD is not tradable.
    assert crypto_universe(assets, bars, 2, []) == ["BTC/USD", "ETH/USD"];
    assert crypto_universe(assets, bars, 2, ["SOL/USD", "BTC/USD"]) == ["BTC/USD", "ETH/USD", "SOL/USD"];
    assert crypto_universe(assets, bars, 0, ["SOL/USD"]) == ["SOL/USD"];
}

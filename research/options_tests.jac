"""Option symbols and contract choice (research/options.jac)."""
import from research.options { OptionContract, OptionQuote, choose_contract, describe_option, expiry_window, parse_occ }
import from models.research { Stamp }

def contract(symbol: str, tradable: bool = True) -> OptionContract {
    parts = parse_occ(symbol);
    assert parts is not None;
    return OptionContract(symbol=symbol, underlying=parts.underlying, kind=parts.kind, strike=parts.strike, expiry=parts.expiry, tradable=tradable);
}

test "an OCC symbol reads back as its underlying, expiry, kind, and strike" {
    parts = parse_occ("AAPL261218C00200000");
    assert parts is not None;
    assert (parts.underlying, parts.expiry, parts.kind, parts.strike) == ("AAPL", "2026-12-18", "call", 200.0);
    put = parse_occ("SPY270115P00412500");
    assert put is not None and put.strike == 412.5 and put.kind == "put";
    assert parse_occ("AAPL") is None and parse_occ("AAPL261340C00200000") is None;
    assert describe_option("AAPL261218C00200000") == "AAPL $200 call, Dec 18, 2026";
}

test "a call is the nearest strike at or above the price, at the expiry nearest the target" {
    listed = [contract(s) for s in ["XYZ261218C00095000", "XYZ261218C00100000", "XYZ261218C00105000", "XYZ270115C00100000", "XYZ261127C00100000"]];
    # 2026-11-16 plus 35 days is 2026-12-21: December 18 is nearest; November 27 is under 21 days.
    found = choose_contract(listed, 98.0, "call", "2026-11-16", 21, 60, 35);
    assert found is not None and found.symbol == "XYZ261218C00100000";
}

test "a put is the nearest strike at or below the price, and nothing fits outside the window" {
    listed = [contract(s) for s in ["XYZ261218P00095000", "XYZ261218P00100000", "XYZ261218P00105000"]];
    chosen = choose_contract(listed, 98.0, "put", "2026-11-16", 21, 60, 35);
    assert chosen is not None and chosen.symbol == "XYZ261218P00095000";
    assert choose_contract(listed, 98.0, "put", "2026-11-16", 40, 60, 45) is None;
    assert choose_contract([contract("XYZ261218C00100000", tradable=False)], 98.0, "call", "2026-11-16", 21, 60, 35) is None;
}

test "the expiry window runs from min to max days out" {
    assert expiry_window("2026-11-16", 21, 60) == ("2026-12-07", "2027-01-15");
}

test "a quote's mid and spread need both sides" {
    stamp = Stamp(source="alpaca_data", dataset="alpaca.option_snapshots", source_url="https://data.alpaca.markets/", published_at="2026-11-16T15:00:00+00:00", fetched_at="2026-11-16T15:00:00+00:00");
    quote = OptionQuote(symbol="X", bid=1.0, ask=1.2, at="2026-11-16T15:00:00Z", stamp=stamp);
    assert abs(quote.mid() - 1.1) < 1e-9 and abs(quote.spread() - 0.2 / 1.1) < 1e-9;
    assert OptionQuote(symbol="X", bid=0.0, ask=1.2, at="t", stamp=stamp).mid() == 0.0;
}

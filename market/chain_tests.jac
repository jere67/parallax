"""A stock's option chain (market/chain.jac): rows by strike for one expiry, and the demo's
invented chain."""
import from datetime { date }
import from market.chain { ChainQuote, chain_rows, demo_chain, expiries_of, occ_symbol }
import from research.options { CALL, OptionContract, PUT, parse_occ }

def contract(kind: str, strike: float, expiry: str, interest: float = 0.0) -> OptionContract {
    return OptionContract(symbol=occ_symbol("AAPL", expiry, kind, strike), underlying="AAPL", kind=kind, strike=strike, expiry=expiry, tradable=True, open_interest=interest);
}

test "a chain's rows pair each strike's call and put for one expiry, with open interest from the list" {
    listed = [
        contract(CALL, 200.0, "2026-12-18", 50.0),
        contract(PUT, 200.0, "2026-12-18"),
        contract(CALL, 190.0, "2026-12-18"),
        contract(CALL, 200.0, "2027-01-15")
    ];
    assert expiries_of(listed) == ["2026-12-18", "2027-01-15"];
    call = listed[0].symbol;
    rows = chain_rows(listed, "2026-12-18", {call: ChainQuote(symbol=call, bid=4.1, ask=4.3)});
    assert [r.strike for r in rows] == [190.0, 200.0];
    assert rows[0].put is None and rows[0].call is not None and rows[0].call.bid is None;
    found = rows[1].call;
    assert found is not None and found.bid == 4.1 and found.open_interest == 50.0 and rows[1].put is not None;
}

test "an invented chain is centered on the price, prices calls and puts sensibly, and repeats" {
    today = date(2026, 11, 16);
    (listed, quotes) = demo_chain("AAPL", 232.0, today);
    expiries = expiries_of(listed);
    assert len(expiries) == 4 and all(e > today.isoformat() for e in expiries);
    assert all(date.fromisoformat(e).weekday() == 4 for e in expiries);
    strikes = sorted(set(c.strike for c in listed));
    assert strikes[0] < 232.0 < strikes[-1];
    for c in listed {
        parts = parse_occ(c.symbol);
        assert parts is not None and parts.strike == c.strike and parts.expiry == c.expiry and parts.kind == c.kind;
        q = quotes[c.symbol];
        assert q.bid is not None and q.ask is not None and 0.0 <= q.bid <= q.ask;
    }
    deep_call = [c for c in listed if c.kind == CALL and c.expiry == expiries[0]][0];
    delta = quotes[deep_call.symbol].delta;
    assert delta is not None and delta > 0.8, delta;
    (again, _) = demo_chain("AAPL", 232.0, today);
    assert [c.symbol for c in again] == [c.symbol for c in listed];
}

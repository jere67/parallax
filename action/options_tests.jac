"""Long calls and puts (action/options.jac): the option tick, and when an open contract is sold."""
import from action.options { OptionsConfig, exit_reason, to_tick }
import from models.graph { Decision, Position, TradeAction }
import from models.research { Stamp }
import from research.options { OptionQuote }

glob STAMP: Stamp = Stamp(source="alpaca_data", dataset="alpaca.option_snapshots", source_url="https://data.alpaca.markets/", published_at="2026-11-16T15:00:00+00:00", fetched_at="2026-11-16T15:00:00+00:00");

def call_held(paid: float = 2.0) -> Position {
    return Position(ticker="XYZ261218C00100000", sector="", qty=2, avg_entry_price=paid, opened_at="2026-11-16T15:00:00+00:00", asset_class="us_option", multiplier=100.0);
}

def quote(bid: float, ask: float) -> OptionQuote {
    return OptionQuote(symbol="XYZ261218C00100000", bid=bid, ask=ask, at="2026-11-20T15:00:00Z", stamp=STAMP);
}

def said(action: TradeAction) -> Decision {
    return Decision(ticker="XYZ", action=action, conviction=0.5, thesis="t");
}

test "option prices round to a nickel from $3 and a penny below" {
    assert to_tick(3.42, True) == 3.45 and to_tick(3.42, False) == 3.4;
    assert to_tick(1.234, True) == 1.24 and to_tick(1.234, False) == 1.23;
    assert to_tick(0.001, False) == 0.01;
}

test "an open call is kept while nothing calls for its sale" {
    assert exit_reason(call_held(), "2026-11-20", quote(1.9, 2.1), said(TradeAction.HOLD)) == "";
}

test "an open call is sold near expiry, on a halved or doubled premium, or when the panel turns" {
    assert "days to expiry" in exit_reason(call_held(), "2026-12-12", quote(1.9, 2.1), None);
    assert "fell to 50%" in exit_reason(call_held(), "2026-11-20", quote(0.9, 1.1), None);
    assert "rose to 200%" in exit_reason(call_held(), "2026-11-20", quote(3.9, 4.1), None);
    assert "now says SELL" in exit_reason(call_held(), "2026-11-20", quote(1.9, 2.1), said(TradeAction.SELL));
    # A buy on the stock does not turn a call around.
    assert exit_reason(call_held(), "2026-11-20", quote(1.9, 2.1), said(TradeAction.BUY)) == "";
}

test "the exit limits are the config's" {
    loose = OptionsConfig(loss_exit=0.2, gain_exit=5.0, exit_days=1);
    assert exit_reason(call_held(), "2026-12-12", quote(0.9, 1.1), None, loose) == "";
}

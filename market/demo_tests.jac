"""The invented market: complete enough for every page, repeatable, and nothing written anywhere."""
import from datetime { date }
import from market.demo { demo_history, demo_state }
import from market.rows { build_rows }

glob DAY: date = date(2026, 11, 5);

test "every invented stock has what the pages show" {
    state = demo_state(DAY);
    rows = build_rows(state, DAY);
    assert len(rows) > 50;
    assert state.demo;
    for row in rows {
        symbol = row["symbol"];
        assert row["price"] is not None, symbol;
        assert row["market_cap"] is not None, symbol;
        assert row["sector"], symbol;
        assert row["tech_rating"], symbol;
        assert row["analyst_rating"], symbol;
        assert state.company(state.listings[str(symbol)].cik) is not None, symbol;
    }
}

test "invented stocks move with an invented market, and report on working days" {
    state = demo_state(DAY);
    betas = [s.beta for s in state.stats.values() if s.beta is not None];
    assert len(betas) == len(state.stats);
    assert sum(betas) / len(betas) > 0.5;
    for dates in state.earnings.values() {
        assert date.fromisoformat(dates.next_day).weekday() < 5;
        assert date.fromisoformat(dates.last_day).weekday() < 5;
    }
}

test "the same day invents the same market" {
    first = {r["symbol"]: r["price"] for r in build_rows(demo_state(DAY), DAY)};
    second = {r["symbol"]: r["price"] for r in build_rows(demo_state(DAY), DAY)};
    assert first == second;
    bars = demo_history("AAPL", DAY);
    assert bars == demo_history("AAPL", DAY) or [b.close for b in bars] == [b.close for b in demo_history("AAPL", DAY)];
    assert bars[-1].day <= DAY.isoformat();
    assert all(b.low <= b.close <= b.high for b in bars);
}

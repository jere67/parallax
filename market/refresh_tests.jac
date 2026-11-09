"""When the sweeps run and what they read next. No network: only the choosing is under test."""
import from datetime { datetime, timezone }
import from market.listings { Listing }
import from market.prices { Quote }
import from market.refresh { company_queue, merged_earnings, quiet, seconds_since, session_hours }
import from market.state { CompanySummary, EarningsDates, MarketState }

def utc(y: int, mo: int, d: int, h: int, mi: int = 0) -> datetime {
    return datetime(y, mo, d, h, mi, tzinfo=timezone.utc);
}

test "the sweeps stand aside for the morning run on weekdays" {
    # November: New York is five hours behind UTC.
    assert quiet(utc(2026, 11, 5, 13, 0));
    assert not quiet(utc(2026, 11, 5, 12, 0));
    assert not quiet(utc(2026, 11, 5, 15, 0));
    assert not quiet(utc(2026, 11, 7, 13, 0));
}

test "session hours run from pre-market to after hours on weekdays" {
    assert session_hours(utc(2026, 11, 5, 15, 0));
    assert not session_hours(utc(2026, 11, 5, 8, 0));
    assert not session_hours(utc(2026, 11, 7, 15, 0));
}

test "an unreadable time counts as long ago" {
    assert seconds_since("", utc(2026, 11, 5, 15, 0)) == float("inf");
    assert seconds_since("soon", utc(2026, 11, 5, 15, 0)) == float("inf");
    assert seconds_since("2026-11-05T14:59:00+00:00", utc(2026, 11, 5, 15, 0)) == 60.0;
}

test "earnings keep the newest past date and the soonest future one" {
    earlier = {
        "A": EarningsDates(last_day="2026-08-01", next_day="2026-11-01"),
        "B": EarningsDates(last_day="2026-08-01", next_day="2026-12-01")
    };
    found = merged_earnings(earlier, [("B", "2026-11-20", "amc"), ("B", "2026-11-25", "bmo"), ("C", "2026-10-30", "")], "2026-11-05");
    assert found["A"].last_day == "2026-11-01" and found["A"].next_day == "";
    assert found["B"].next_day == "2026-11-20" and found["B"].next_hour == "amc";
    assert found["C"].last_day == "2026-10-30" and found["C"].next_day == "";
}

test "the company sweep reads the never-read first, then members, then the most traded" {
    state = MarketState(demo=True);
    def add(symbol: str, cik: str, sp500: bool, volume: float) {
        state.listings[symbol] = Listing(symbol=symbol, name=symbol, cik=cik, exchange="Nasdaq", kind="common", sp500=sp500);
        state.quotes[symbol] = Quote(symbol=symbol, day="2026-11-05", price=10.0, volume=volume);
    }
    add("OLD", "1", True, 1.0);
    add("SMALL", "2", False, 1.0);
    add("BIG", "3", False, 1000.0);
    add("MEMBER", "4", True, 1.0);
    add("DONE", "5", True, 1.0);
    state.companies["1"] = CompanySummary(cik="1", checked="2026-11-01");
    state.companies["5"] = CompanySummary(cik="5", checked="2026-11-05");
    assert company_queue(state, "2026-11-05") == ["4", "3", "2", "1"];
}

test "two lines of one company are one read, ranked by the better line" {
    state = MarketState(demo=True);
    state.listings["GOOG"] = Listing(symbol="GOOG", name="g", cik="9", exchange="Nasdaq", kind="common", sp500=True);
    state.listings["GOOGL"] = Listing(symbol="GOOGL", name="g", cik="9", exchange="Nasdaq", kind="common");
    assert company_queue(state, "2026-11-05") == ["9"];
}

"""The chart's ranges and each range's change (dashboard/market/ranges.jac)."""
import from dashboard.market.ranges { bars_for, last_session, months_before, range_base, range_change }
import from models.market { BarView }

def daily(day: str, close: float) -> BarView {
    return BarView(time=day, open=close, high=close, low=close, close=close, volume=1.0);
}

def intraday(at: int, close: float) -> BarView {
    return BarView(time=at, open=close, high=close, low=close, close=close, volume=1.0);
}

glob BARS: list[BarView] = [
    daily("2024-11-04", 50.0),
    daily("2025-11-03", 80.0),
    daily("2025-12-31", 90.0),
    daily("2026-01-02", 100.0),
    daily("2026-10-05", 110.0),
    daily("2026-11-02", 120.0),
    daily("2026-11-03", 130.0)
];

test "months back land on a date that exists" {
    assert months_before("2026-03-31", 1) == "2026-02-28";
    assert months_before("2026-01-15", 1) == "2025-12-15";
    assert months_before("2026-11-05", 120) == "2016-11-05";
}

test "a range holds the bars from its start" {
    assert [b.close for b in bars_for("YTD", BARS, [])] == [100.0, 110.0, 120.0, 130.0];
    assert [b.close for b in bars_for("1M", BARS, [])] == [110.0, 120.0, 130.0];
    assert len(bars_for("Max", BARS, [])) == len(BARS);
}

test "a range the history does not reach is empty, not misleading" {
    assert bars_for("10Y", BARS, []) == [];
    assert range_change("10Y", BARS, []) is None;
}

test "a range's base is the last close before it starts" {
    assert range_base("YTD", BARS) == 90.0;
    assert range_base("1M", BARS) == 100.0;
    assert range_base("Max", BARS) == 50.0;
    assert range_base("10Y", BARS) is None;
    assert range_base("1D", BARS[:1]) is None;
}

test "the one-day change is against the previous close" {
    assert abs(range_change("1D", BARS, []) - (130.0 / 120.0 - 1.0)) < 1e-9;
}

test "no bars means no change, in every range" {
    for name in ["1D", "5D", "1M", "YTD", "Max"] {
        assert range_change(name, [], []) is None, name;
        assert bars_for(name, [], []) == [], name;
    }
}

test "the five-day change needs six sessions" {
    assert range_change("5D", BARS[-3:], []) is None;
    assert abs(range_change("5D", BARS, []) - (130.0 / 80.0 - 1.0)) < 1e-9;
}

test "the last session is the newest New York date" {
    # 15:00 UTC on two days, and a bar just after midnight UTC that is still the second day in New York.
    first = 1793977200;
    second = first + 86400;
    bars = [intraday(first, 1.0), intraday(second, 2.0), intraday(second + 34200, 3.0)];
    assert [b.close for b in last_session(bars)] == [2.0, 3.0];
    assert last_session([]) == [];
}

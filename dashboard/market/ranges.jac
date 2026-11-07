"""The price chart's ranges. Plain functions over plain bars, so `jac test` covers them.

A range's change is against the last close before it starts, as a quote reads: one day is against
the previous close, and the year to date is against last year's last close. The history begins in
2016, so "Max" says so rather than claiming all time."""
import from models.market { BarView as Bar }

glob RANGES: list[str] = ["1D", "5D", "1M", "3M", "6M", "YTD", "1Y", "5Y", "10Y", "Max"];
glob MONTHS_BACK: dict[str, int] = {"1M": 1, "3M": 3, "6M": 6, "1Y": 12, "5Y": 60, "10Y": 120};
glob DAY_SECONDS: int = 86400;
glob NY_OFFSET_SECONDS: int = 4 * 3600;

"""`day` less `months`, on the same day of the month or the last one that exists."""
def months_before(day: str, months: int) -> str {
    y = int(day[0:4]);
    m = int(day[5:7]) - months;
    while m < 1 {
        m += 12;
        y -= 1;
    }
    d = min(int(day[8:10]), 28);
    month = f"0{m}" if m < 10 else str(m);
    dd = f"0{d}" if d < 10 else str(d);
    return f"{y}-{month}-{dd}";
}

"""The first bar of the range, from daily bars. -1 when the bars do not reach back that far."""
def range_start(name: str, daily: list[Bar]) -> int {
    if len(daily) == 0 {
        return -1;
    }
    last = str(daily[len(daily) - 1].time);
    start = "";
    if name == "YTD" {
        start = last[0:4] + "-01-01";
    } elif name in MONTHS_BACK {
        start = months_before(last, MONTHS_BACK[name]);
    } elif name != "Max" {
        return -1;
    }
    if name in MONTHS_BACK and str(daily[0].time) > start {
        return -1;
    }
    for (i, bar) in enumerate(daily) {
        if str(bar.time) >= start {
            return i;
        }
    }
    return -1;
}

"""The bars of a daily range."""
def daily_range(name: str, daily: list[Bar]) -> list[Bar] {
    start = range_start(name, daily);
    return daily[start:] if start >= 0 else [];
}

"""The newest session's bars out of five sessions of intraday bars, by New York's date."""
def last_session(intraday: list[Bar]) -> list[Bar] {
    if len(intraday) == 0 {
        return [];
    }
    def day_of(bar: Bar) -> int {
        return (int(bar.time) - NY_OFFSET_SECONDS) // DAY_SECONDS;
    }
    newest = day_of(intraday[len(intraday) - 1]);
    return [b for b in intraday if day_of(b) == newest];
}

"""The bars a range shows."""
def bars_for(name: str, daily: list[Bar], intraday: list[Bar]) -> list[Bar] {
    if name == "1D" {
        return last_session(intraday);
    }
    if name == "5D" {
        return intraday;
    }
    return daily_range(name, daily);
}

"""The price a range's change is against: the last close before the range starts. None when the bars
do not reach back that far."""
def range_base(name: str, daily: list[Bar]) -> float | None {
    if len(daily) < 2 {
        return None;
    }
    if name == "1D" {
        return daily[len(daily) - 2].close;
    }
    if name == "5D" {
        return daily[len(daily) - 6].close if len(daily) > 5 else None;
    }
    start = range_start(name, daily);
    if start < 0 {
        return None;
    }
    return daily[start - 1].close if start > 0 else daily[start].close;
}

"""The change over a range, or None when the record does not cover it."""
def range_change(name: str, daily: list[Bar], intraday: list[Bar]) -> float | None {
    if len(daily) < 2 {
        return None;
    }
    base = range_base(name, daily);
    return daily[len(daily) - 1].close / base - 1.0 if base else None;
}

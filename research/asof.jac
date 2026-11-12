"""History-only collection for a replay of a past morning (TDD §13, look-ahead control).

A replay sets the decision time, 7:30 a.m. New York on the day it replays, and every collector
then serves only what was published before it: dated items published at or after it are
dropped as stale (research/collector.jac, `split_fresh`), news queries end at it, SEC filings
and XBRL facts filed on or after its date are left out, an earnings calendar row keeps its
actual figures only for a release before that day, and the current month's analyst counts,
which Finnhub keeps updating, are left out. A source that only has today's snapshot (Finnhub's
key metrics) is not read at all. The live pipeline never sets it: the mode is off unless a
replay calls `enter_as_of`, so every function here is a no-op for a live run.

The setting is process-wide, not per thread, because collectors run on the shared worker pool,
whose threads would not see a context variable. A replay is its own process.
"""
import from datetime { date, datetime, time, timezone }
import from zoneinfo { ZoneInfo }

glob DECISION_TIME: time = time(7, 30);
glob NEW_YORK: ZoneInfo = ZoneInfo("America/New_York");

"""When the replayed decision is made, or None outside a replay."""
obj AsOfClock {
    has at: datetime | None = None;
}

glob CLOCK: AsOfClock = AsOfClock();

"""7:30 a.m. New York on `run_day` (ISO date), in UTC: when a morning run starts deciding."""
def decision_time(run_day: str) -> datetime {
    return datetime.combine(date.fromisoformat(run_day), DECISION_TIME, NEW_YORK).astimezone(timezone.utc);
}

"""Serve only data published before `at` until `leave_as_of`."""
def enter_as_of(at: datetime) {
    if at.tzinfo is None {
        raise ValueError("the decision time needs a time zone");
    }
    CLOCK.at = at.astimezone(timezone.utc);
}

def leave_as_of {
    CLOCK.at = None;
}

"""The replay's decision time, or None for a live run."""
def as_of_time -> datetime | None {
    return CLOCK.at;
}

"""The New York date of the decision ("" for a live run). A filing dated that day or later
was not public before 7:30 a.m., since EDGAR dates a filing by its acceptance day."""
def as_of_day -> str {
    return CLOCK.at.astimezone(NEW_YORK).date().isoformat() if CLOCK.at is not None else "";
}

"""The decision time as an RFC 3339 timestamp for a query's end ("" for a live run)."""
def as_of_end -> str {
    return CLOCK.at.strftime("%Y-%m-%dT%H:%M:%SZ") if CLOCK.at is not None else "";
}

"""True when something filed on `day` (ISO date) was public at the decision; always True
for a live run."""
def filed_in_time(day: str) -> bool {
    return CLOCK.at is None or (bool(day) and day[:10] < as_of_day());
}

"""True when something published at `when` was public at the decision; always True for a live
run. `when` is a datetime with a zone."""
def published_in_time(when: datetime) -> bool {
    return CLOCK.at is None or when < CLOCK.at;
}

"""The first day of the decision's month ("" for a live run): a monthly figure for that month
was still changing at the decision."""
def open_month -> str {
    day = as_of_day();
    return day[:8] + "01" if day else "";
}

"""Which EPS quarters (`periods`, quarter-end dates) were reported before the decision, given
the days the company filed earnings releases (`release_days`, Item 2.02 8-Ks): a quarter is
reported once a release was filed after it ended and before the decision day. All of them for
a live run."""
def reported_periods(periods: list[str], release_days: list[str]) -> set[str] {
    if CLOCK.at is None {
        return set(periods);
    }
    cutoff = as_of_day();
    filed = sorted(d for d in release_days if d < cutoff);
    return {p for p in periods if any(d > p for d in filed)};
}

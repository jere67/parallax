"""When the team's morning job starts a run: the New York morning window at both UTC offsets
across the clock change, and never twice in a day."""
import from datetime { datetime, timezone }
import from action.fixtures { finished_run, team }
import from run.guard { NEW_YORK, morning_window }
import from run.jobs { morning_due }

def at(utc: str) -> datetime {
    return datetime.fromisoformat(utc).replace(tzinfo=timezone.utc).astimezone(NEW_YORK);
}

test "in daylight time the window is 11:30 to 13:15 UTC" {
    assert not morning_window(at("2026-10-16T11:29:59"));
    assert morning_window(at("2026-10-16T11:30:00"));
    assert morning_window(at("2026-10-16T13:14:59"));
    assert not morning_window(at("2026-10-16T13:15:00"));
}

test "in standard time the window is 12:30 to 14:15 UTC, inside the job's 11:00 to 14:59 firings" {
    assert not morning_window(at("2026-11-02T11:30:00"));
    assert morning_window(at("2026-11-02T12:30:00"));
    assert morning_window(at("2026-11-02T14:14:59"));
    assert not morning_window(at("2026-11-02T14:15:00"));
}

test "weekends are never in the window" {
    assert not morning_window(at("2026-10-17T11:30:00"));
    assert not morning_window(at("2026-11-08T13:00:00"));
}

test "a server that wakes after 7:45 still starts the day's run, before the team portfolio exists too" {
    assert morning_due(None, at("2026-11-10T14:00:00"));
    assert morning_due(team(), at("2026-11-10T14:00:00"));
}

test "once the day has a run, later firings do nothing, but the next day's run is due" {
    portfolio = team();
    finished_run(portfolio, "2026-11-10", []);
    assert not morning_due(portfolio, at("2026-11-10T12:31:00"));
    assert morning_due(portfolio, at("2026-11-11T12:31:00"));
}

test "outside the window nothing is due, whatever the record" {
    assert not morning_due(None, at("2026-11-10T12:29:00"));
    assert not morning_due(team(), at("2026-11-10T14:15:00"));
}

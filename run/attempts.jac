"""The team's morning run as this process saw it, so a run the server could not save is still
on record (#240).

A scheduled firing's writes commit only when the firing ends. On 2026-11-12 the team's run
worked from 7:30 to 10:00, and then its commit failed (`scheduled morning_job failed: 40001`,
against the trading tick's writes), which threw away the Run its claim had made along with all
its work. The Runs page said "No run", the evaluation counted the day as missed, not failed,
and nothing said why.

`morning_run` (run/orchestration.jac) notes here when a team run starts and when its work ends.
While one is working, or ended less than GRACE ago and is not in the graph yet, the trading
tick leaves the team portfolio alone, so the two never write it at once, and neither the
morning job nor a manual request starts another. Once GRACE has passed with no run in the
graph for that day, `record_lost` writes one: failed, saying when it worked and that none of it
was kept. The admin may then run the day again (run/manual.jac).

This lives in the process, like `_RUNNING` and `_CLAIMED` for agents (run/agents.jac), so it
assumes one server, as the deployment does. A restart forgets it: a run lost just before a
restart stays missing, and the evaluation counts its day as missed.
"""
import threading;
import from datetime { datetime, timedelta }
import from models.graph { Portfolio, Ran, Run, RunStatus }
import from run.guard { NEW_YORK }
import from run.public { public }

# How long a run's commit may take after its work ends before the run counts as lost.
glob GRACE: timedelta = timedelta(minutes=3);
glob MAX_SUMMARY_CHARS: int = 2000;

"""One team run for `day`: when its work started and ended, and how it said it ended."""
obj Attempt {
    has day: str,
        started_at: datetime;
    has ended_at: datetime | None = None,
        status: str = "",
        summary: str = "";
}

glob _LOCK: threading.Lock = threading.Lock();
glob _ATTEMPTS: dict[str, Attempt] = {};

def begin(day: str, now: datetime) {
    with _LOCK {
        _ATTEMPTS[day] = Attempt(day=day, started_at=now);
    }
}

"""Note that the run for `day` finished its work at `now`, how it ended, and its summary."""
def finish(day: str, now: datetime, status: str = "", summary: str = "") {
    with _LOCK {
        found = _ATTEMPTS.get(day);
        if found is not None {
            found.ended_at = now;
            found.status = status;
            found.summary = summary;
        }
    }
}

def forget(day: str) {
    with _LOCK {
        _ATTEMPTS.pop(day, None);
    }
}

def attempt_for(day: str) -> Attempt | None {
    with _LOCK {
        return _ATTEMPTS.get(day);
    }
}

"""True while the team's run for `day` is still doing its work in this process."""
def working(day: str) -> bool {
    found = attempt_for(day);
    return found is not None and found.ended_at is None;
}

"""True when the graph holds a finished run for `day` on `portfolio`."""
def saved(portfolio: Portfolio, day: str) -> bool {
    return any(r.run_date == day and r.status != RunStatus.RUNNING for r in [portfolio ->:Ran:->[?:Run]]);
}

"""True while the team's run for `day` may still write the team portfolio: it is working, or it
ended less than GRACE before `now` and is not in the graph yet. A run found saved is forgotten."""
def busy(portfolio: Portfolio, day: str, now: datetime) -> bool {
    found = attempt_for(day);
    if found is None {
        return False;
    }
    if found.ended_at is None {
        return True;
    }
    if saved(portfolio, day) {
        forget(day);
        return False;
    }
    return now - found.ended_at < GRACE;
}

"""The runs whose work ended at least GRACE before `now`, whose record this process has not
seen yet. Needs no graph read, so a job can ask every minute."""
def unsettled(now: datetime) -> list[Attempt] {
    with _LOCK {
        return [a for a in _ATTEMPTS.values() if a.ended_at is not None and now - a.ended_at >= GRACE];
    }
}

"""Write a failed run for every day whose run ended at least GRACE ago and is still not in the
graph, and forget each one found saved. The record stays in this process until a later call
finds it saved, so a record whose own commit fails is written again. Returns a line per run
recorded."""
def record_lost(portfolio: Portfolio, now: datetime) -> list[str] {
    lines: list[str] = [];
    for found in unsettled(now) {
        if saved(portfolio, found.day) {
            forget(found.day);
            continue;
        }
        public(portfolio +>:Ran():+> Run(
            run_date=found.day,
            started_at=found.started_at.isoformat(),
            status=RunStatus.FAILED,
            finished_at=(found.ended_at or now).isoformat(),
            summary=lost_summary(found)
        ));
        lines.append(f"{found.day}: recorded the lost run as failed");
    }
    return lines;
}

"""What a lost run's record says: when it worked, that nothing of it was kept, and how it had
ended, in its own words."""
def lost_summary(found: Attempt) -> str {
    ended = found.ended_at or found.started_at;
    text = f"Lost: the run worked from {_clock(found.started_at)} to {_clock(ended)} ET, but the server could not save it, so none of its research, votes, or decisions were kept and no order was sent for them. The admin can run the day again.";
    if found.summary {
        text += f" It had ended: {found.summary}";
    }
    text = " ".join(text.split());
    return text if len(text) <= MAX_SUMMARY_CHARS else text[:MAX_SUMMARY_CHARS - 1].rstrip() + "…";
}

def _clock(at: datetime) -> str {
    local = at.astimezone(NEW_YORK);
    return f"{local.hour % 12 or 12}:{local.minute:02d} {'AM' if local.hour < 12 else 'PM'}";
}

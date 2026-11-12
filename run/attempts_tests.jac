"""A team run this process started is waited for while it may still write, and recorded as
failed when the server could not save it (run/attempts.jac, #240). The tracker lives in the
process, so each test uses its own day and forgets it at the end."""
import from datetime { datetime, timedelta, timezone }
import from action.fixtures { Call, finished_run, team }
import from models.graph { Ran, Run, RunStatus, TradeAction }
import from run.attempts { GRACE, attempt_for, begin, busy, finish, forget, record_lost, unsettled }
import from run.guard { NEW_YORK, claim_run, rerunnable }
import from run.jobs { morning_due }
import from run.manual { manual_refusal }
import run.orchestration as orchestration;

def at(day: str, hhmm: str) -> datetime {
    return datetime.fromisoformat(f"{day}T{hhmm}:00").replace(tzinfo=NEW_YORK).astimezone(timezone.utc);
}

def runs_on(portfolio: object, day: str) -> list[Run] {
    return [r for r in [portfolio ->:Ran:->[?:Run]] if r.run_date == day];
}

test "a run the server could not save is recorded as failed once its grace has passed, and only once" {
    day = "2026-11-12";
    portfolio = team();
    try {
        begin(day, at(day, "07:30"));
        assert busy(portfolio, day, at(day, "09:45"));
        # The work ended at 10:00 and its commit failed: nothing reached the graph.
        finish(day, at(day, "10:00"), "fallback", "Ran out of time: the run passed its 90-minute deadline.");
        assert busy(portfolio, day, at(day, "10:01"));
        assert unsettled(at(day, "10:01")) == [] and record_lost(portfolio, at(day, "10:01")) == [];
        late = at(day, "10:00") + GRACE;
        assert not busy(portfolio, day, late);
        assert record_lost(portfolio, late) == [f"{day}: recorded the lost run as failed"];
        found = runs_on(portfolio, day);
        assert len(found) == 1 and found[0].status == RunStatus.FAILED;
        assert found[0].summary.startswith("Lost: the run worked from 7:30 AM to 10:00 AM ET, but the server could not save it"), found[0].summary;
        assert found[0].summary.endswith("It had ended: Ran out of time: the run passed its 90-minute deadline.");
        assert found[0].started_at == at(day, "07:30").isoformat() and rerunnable(found[0]);
        # The next firing finds the record and forgets the run, writing nothing more.
        assert record_lost(portfolio, late + timedelta(minutes=1)) == [];
        assert attempt_for(day) is None and len(runs_on(portfolio, day)) == 1;
    } finally {
        forget(day);
    }
}

test "a run that is saved is forgotten and never recorded as lost" {
    day = "2026-11-13";
    portfolio = team();
    try {
        begin(day, at(day, "07:30"));
        finished_run(portfolio, day, []);
        finish(day, at(day, "08:20"), "normal");
        assert not busy(portfolio, day, at(day, "08:20"));
        assert attempt_for(day) is None;
        assert record_lost(portfolio, at(day, "09:00")) == [] and len(runs_on(portfolio, day)) == 1;
    } finally {
        forget(day);
    }
}

test "while a run is noted the schedule does not start another, and the admin may not either" {
    day = "2026-11-16";
    portfolio = team();
    local = at(day, "08:00").astimezone(NEW_YORK);
    try {
        assert morning_due(portfolio, local);
        begin(day, at(day, "07:30"));
        assert not morning_due(portfolio, local);
        assert manual_refusal(True, portfolio, day, local) == f"The run for {day} is running now.";
        finish(day, at(day, "08:30"), "normal");
        assert manual_refusal(True, portfolio, day, at(day, "08:31").astimezone(NEW_YORK)) == f"The run for {day} has just finished and is being saved.";
        # Lost and recorded, the day is left to the admin, who may run it again.
        record_lost(portfolio, at(day, "08:30") + GRACE);
        assert not morning_due(portfolio, at(day, "08:40").astimezone(NEW_YORK));
        assert manual_refusal(True, portfolio, day, at(day, "08:40").astimezone(NEW_YORK)) == "";
    } finally {
        forget(day);
    }
}

test "only a run that failed before deciding anything is claimed again, on the same record" {
    day = "2026-11-17";
    portfolio = team();
    try {
        begin(day, at(day, "07:30"));
        finish(day, at(day, "09:00"), "fallback");
        record_lost(portfolio, at(day, "09:00") + GRACE);
        lost = runs_on(portfolio, day)[0];
        assert claim_run(portfolio, day) is None;
        again = claim_run(portfolio, day, rerun=True);
        assert again is not None and again is lost and again.status == RunStatus.RUNNING;
        assert again.summary == "" and again.finished_at == "" and again.executed_at == "";
        assert "rerun: the day is run again after: Lost: the run worked from 7:30 AM to 9:00 AM ET" in again.action_log[-1];
        assert len(runs_on(portfolio, day)) == 1;
        # A run that decided something is never claimed again.
        other = team();
        decided = finished_run(other, day, [Call(ticker="AAA", action=TradeAction.HOLD)]);
        decided.status = RunStatus.FAILED;
        assert not rerunnable(decided) and claim_run(other, day, rerun=True) is None;
    } finally {
        forget(day);
    }
}

def fall_over(*_args: object, **_kwargs: object) -> object {
    raise RuntimeError("the market calendar fell over");
}

test "a run that fails before claiming its day is forgotten, so the next firing tries again" {
    day = "2026-11-18";
    original = orchestration.daily_run;
    setattr(orchestration, "daily_run", fall_over);
    try {
        raised = False;
        try {
            orchestration.morning_run(day);
        } except RuntimeError {
            raised = True;
        }
        assert raised and attempt_for(day) is None and unsettled(at(day, "09:00")) == [];
        assert morning_due(team(), at(day, "07:31").astimezone(NEW_YORK));
    } finally {
        setattr(orchestration, "daily_run", original);
        forget(day);
    }
}

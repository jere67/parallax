"""Who may start a manual morning run, and when (run/manual.jac). The admin check and the job
it queues need the live server; the end-to-end check in the PR covers them."""
import from datetime { datetime }
import from action.fixtures { finished_run, team }
import from models.graph { PortfolioMode }
import from run.guard { NEW_YORK }
import from run.manual { manual_refusal, request_run, seconds_left_today, take_request }

glob MONDAY: str = "2026-11-02";

def at(day: str, hhmm: str) -> datetime {
    return datetime.fromisoformat(f"{day}T{hhmm}:00").replace(tzinfo=NEW_YORK);
}

test "the admin may start a weekday's run, before or after the 7:30 slot, even before the team portfolio exists" {
    assert manual_refusal(True, None, MONDAY, at(MONDAY, "10:30")) == "";
    assert manual_refusal(True, team(PortfolioMode.INSIGHT), MONDAY, at(MONDAY, "06:00")) == "";
}

test "anyone but the admin is refused, whatever the day" {
    assert manual_refusal(False, team(), MONDAY, at(MONDAY, "10:30")) == "Only the admin can start a run.";
}

test "a weekend, the demo history, or a day that already has a run is refused" {
    assert manual_refusal(True, team(), "2026-11-01", at("2026-11-01", "10:30")) == "2026-11-01 is a weekend; the market is closed.";
    demo = team();
    demo.demo = True;
    assert manual_refusal(True, demo, MONDAY, at(MONDAY, "10:30")) == "The team portfolio holds the demo history, which never runs.";
    portfolio = team();
    finished_run(portfolio, MONDAY, []);
    assert manual_refusal(True, portfolio, MONDAY, at(MONDAY, "10:30")).startswith(f"The run for {MONDAY} has already started (status: ");
    assert manual_refusal(True, portfolio, "2026-11-03", at("2026-11-03", "10:30")) == "";
}

test "a request is taken once, and only for its own day" {
    request_run(MONDAY, at(MONDAY, "10:30"));
    assert not take_request("2026-11-03");
    assert take_request(MONDAY);
    assert not take_request(MONDAY);
}

test "a request lasts until the end of its New York day" {
    assert seconds_left_today(at(MONDAY, "10:30")) == 13 * 3600 + 30 * 60;
    assert seconds_left_today(at(MONDAY, "23:59")) == 60;
}

"""The Action exit run (tests/runs/action_exit_run.jac): three simulated sessions with zero
gate bypasses, zero drift, and a record that matches the account every evening."""
import from tests.runs.action_exit_run { exit_run }

test "three sessions trade, stop, add, exit, and reconcile with zero bypasses and zero drift" {
    found = exit_run();
    assert found.passed();
    days = {d.day: d for d in found.days};
    assert all(d.run_status == "normal" for d in found.days);
    wed = days["2026-10-21"];
    assert wed.log[0].startswith("09:00 start: forward test started on 2026-10-21: starting balance 100,000.00");
    assert wed.decisions == {"AAPL": "BUY", "MSFT": "BUY", "NVDA": "BUY"} and wed.account == {"AAPL": 36, "MSFT": 10, "NVDA": 36};
    assert "15:50 close: MSFT: stop for 10 at 192.30: pending_new" in wed.log and abs(wed.equity - 100217.4) < 0.01;
    thu = days["2026-10-22"];
    assert "09:45 execute: 1 checks, 1 approved; MSFT buy 26 @ 199.60: new" in thu.log;
    assert "11:00 fill: NVDA: closed @ 191.00 (stop)" in thu.log and thu.account == {"AAPL": 36, "MSFT": 36};
    fri = days["2026-10-23"];
    assert fri.decisions == {"AAPL": "SELL", "MSFT": "SELL", "NVDA": "BUY"} and fri.account == {"NVDA": 38};
    assert "10:00 fill: MSFT: closed @ 199.80 (exit)" in fri.log;
    assert (found.votes_scored, found.votes_total) == (45, 135);
    assert found.baseline_equity == {"equal_weight": {"2026-10-21": 100240.0, "2026-10-22": 99840.0}, "spy": {"2026-10-21": 100400.0, "2026-10-22": 99600.0}};
    assert len(found.orders) == 12 and "NVDA-20261023094600-stop1: sell 38 stop, pending_new, 0 filled" in found.orders;
}

"""Forward-test baselines (action/baselines.jac): the start procedure, the equal-weight
shortlist through sizing, the gate, stops, and time stops, and SPY buy-and-hold, simulated
from daily bars."""
import from datetime { date, datetime, timedelta }
import from action.baselines {
    SimDay,
    advance_baselines,
    baselines_of,
    sim_marks,
    sim_positions,
    simulate_equal_weight,
    start_forward_test
}
import from action.fixtures { Call, broker_for, finished_run, team }
import from analysis.history { History, bar }
import from models.graph { Baseline, BaselineKind, Benchmarks, PortfolioMode, Position, SimHolds, TradeAction }
import from research.alpaca { Bar }
import from run.guard { NEW_YORK }
import from tests.fakes.broker_server { FakeBroker, FakePosition }

def ny(stamp: str) -> datetime {
    return datetime.fromisoformat(stamp).replace(tzinfo=NEW_YORK);
}

"""Weekday sessions from `start` through `end`."""
def weekdays(start: str, end: str) -> list[str] {
    first = date.fromisoformat(start);
    days = [first + timedelta(days=i) for i in range((date.fromisoformat(end) - first).days + 1)];
    return [d.isoformat() for d in days if d.weekday() < 5];
}

def history_of(bars: dict[str, dict[str, Bar]], asked: list[tuple[list[str], str, str]]) -> History {
    def read(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
        asked.append((symbols, start, end));
        return {s: {d: b for (d, b) in bars[s].items() if start <= d <= end} for s in symbols if s in bars};
    }
    return History(bars=read, sessions=weekdays);
}

test "the forward test starts from the flat account's equity, in auto mode, with both baselines" {
    fake = FakeBroker(cash=98765.43);
    try {
        portfolio = team(PortfolioMode.INSIGHT);
        line = start_forward_test(portfolio, broker_for(fake), ny("2026-10-21T09:30:00"), "2026-10-21");
        assert line.startswith("forward test started on 2026-10-21: starting balance 98,765.43");
        assert portfolio.mode == PortfolioMode.AUTO and portfolio.starting_cash == 98765.43 and portfolio.peak_equity == 98765.43;
        found = baselines_of(portfolio);
        assert sorted(k.value for k in found) == ["equal_weight", "spy"];
        assert all(b.cash == 98765.43 and b.start_day == "2026-10-21" and b.simulated_through == "" for b in found.values());
        failed = "";
        try {
            start_forward_test(portfolio, broker_for(fake), ny("2026-10-21T09:31:00"), "2026-10-21");
        } except ValueError as e {
            failed = str(e);
        }
        assert failed == "the forward test has already started" and len(baselines_of(portfolio)) == 2;
    } finally {
        fake.stop();
    }
}

test "an account that is not flat does not start the forward test" {
    fake = FakeBroker();
    try {
        fake.positions["F"] = FakePosition(symbol="F", qty=2, avg_entry_price=12.0);
        portfolio = team(PortfolioMode.INSIGHT);
        failed = "";
        try {
            start_forward_test(portfolio, broker_for(fake), ny("2026-10-21T09:30:00"), "2026-10-21");
        } except ValueError as e {
            failed = str(e);
        }
        assert failed.startswith("the paper account must be flat") and "1 positions (F)" in failed;
        assert portfolio.mode == PortfolioMode.INSIGHT and baselines_of(portfolio) == {};
    } finally {
        fake.stop();
    }
}

test "the equal-weight shortlist buys every pick through the gate, stops out on the low, and marks; SPY buys and holds" {
    fake = FakeBroker();
    try {
        portfolio = team(PortfolioMode.INSIGHT);
        start_forward_test(portfolio, broker_for(fake), ny("2026-10-21T09:30:00"), "2026-10-21");
    } finally {
        fake.stop();
    }
    # The team decided HOLD on CCC, but the baseline buys every pick the screen made.
    finished_run(portfolio, "2026-10-21", [
        Call(ticker="AAA", action=TradeAction.BUY),
        Call(ticker="BBB", action=TradeAction.BUY, sector="Energy", close=50.0, atr=1.0),
        Call(ticker="CCC", action=TradeAction.HOLD),
        Call(ticker="DDD", action=TradeAction.BUY, atr=None)
    ]);
    bars = {
        "AAA": {"2026-10-20": bar("2026-10-20", 99.0), "2026-10-21": bar("2026-10-21", 101.0, open=100.0, low=99.0), "2026-10-22": bar("2026-10-22", 103.0, open=101.0)},
        "BBB": {"2026-10-21": bar("2026-10-21", 48.0, open=50.0, low=47.5)},
        "CCC": {"2026-10-21": bar("2026-10-21", 100.0), "2026-10-22": bar("2026-10-22", 90.0, open=99.0, low=89.0)},
        "DDD": {"2026-10-21": bar("2026-10-21", 100.0)},
        "SPY": {"2026-10-21": bar("2026-10-21", 505.0, open=500.0), "2026-10-22": bar("2026-10-22", 510.0, open=505.0)}
    };
    asked: list[tuple[list[str], str, str]] = [];
    history = history_of(bars, asked);
    # Wednesday's bars are final only that evening, so Wednesday afternoon has nothing to do.
    assert advance_baselines(portfolio, ny("2026-10-21T16:30:00"), history) == [] and asked == [];
    lines = advance_baselines(portfolio, ny("2026-10-22T16:30:00"), history);
    assert asked == [(["AAA", "BBB", "CCC", "DDD", "SPY"], "2026-10-07", "2026-10-21")];
    found = baselines_of(portfolio);
    ew = found[BaselineKind.EQUAL_WEIGHT];
    spy = found[BaselineKind.SPY];
    assert lines == [
        "equal_weight 2026-10-21 AAA bought 80 at 100.00, stop 96.00",
        "equal_weight 2026-10-21 BBB bought 160 at 50.00, stop 48.00",
        "equal_weight 2026-10-21 CCC bought 80 at 100.00, stop 96.00",
        "equal_weight 2026-10-21 DDD buy 80: refused by protective stop",
        "equal_weight 2026-10-21 BBB sold 160 at 48.00 (stop)",
        "equal_weight 2026-10-21 marked 99,760.00 (2 positions, drawdown 0.2%)",
        "spy 2026-10-21 SPY bought 200 at 500.00",
        "spy 2026-10-21 marked 101,000.00 (1 positions, drawdown 0.0%)"
    ];
    assert ew.cash == 100000.0 - 3 * 8000.0 + 160 * 48.0 and ew.simulated_through == "2026-10-21" and ew.peak_equity == 100000.0;
    assert sim_positions(ew)["AAA"].time_stop == "2026-11-04" and spy.cash == 0.0 and spy.peak_equity == 101000.0;
    # Thursday: no run, so no picks; CCC's stop fires at 96, below Thursday's open.
    lines = advance_baselines(portfolio, ny("2026-10-23T16:30:00"), history);
    assert lines == [
        "equal_weight 2026-10-22 CCC sold 80 at 96.00 (stop)",
        "equal_weight 2026-10-22 marked 99,600.00 (1 positions, drawdown 0.4%)",
        "spy 2026-10-22 marked 102,000.00 (1 positions, drawdown 0.0%)"
    ];
    assert sorted(sim_marks(ew)) == ["2026-10-21", "2026-10-22"] and sim_marks(spy)["2026-10-22"].equity == 102000.0;
    assert advance_baselines(portfolio, ny("2026-10-23T16:45:00"), history) == [];
}

test "a time stop sells at the open unless the screen picks the stock again, which renews it" {
    portfolio = team();
    ew = Baseline(kind=BaselineKind.EQUAL_WEIGHT, starting_cash=100000.0, start_day="2026-10-01", cash=84000.0, peak_equity=100000.0);
    portfolio +>:Benchmarks:+> ew;
    ew +>:SimHolds:+> Position(ticker="AAA", sector="Information Technology", qty=80, avg_entry_price=100.0, opened_at="2026-10-07", stop_price=90.0, time_stop="2026-10-21");
    ew +>:SimHolds:+> Position(ticker="BBB", sector="Energy", qty=160, avg_entry_price=50.0, opened_at="2026-10-07", stop_price=45.0, time_stop="2026-10-20");
    run = finished_run(portfolio, "2026-10-21", [Call(ticker="BBB", action=TradeAction.SELL, sector="Energy", close=50.0, atr=1.0)]);
    bars = {"AAA": {"2026-10-21": bar("2026-10-21", 106.0, open=105.0)}, "BBB": {"2026-10-21": bar("2026-10-21", 51.0, open=50.0)}};
    lines = simulate_equal_weight(ew, SimDay(day="2026-10-21", bars=bars, sessions=weekdays("2026-10-01", "2026-11-30"), now=ny("2026-10-22T16:30:00")), run);
    assert lines == ["2026-10-21 AAA sold 80 at 105.00 (time stop)", "2026-10-21 marked 100,560.00 (1 positions, drawdown 0.0%)"];
    held = sim_positions(ew);
    assert list(held) == ["BBB"] and held["BBB"].qty == 160 and held["BBB"].time_stop == "2026-11-04";
}

"""Seeded data never reaches a broker (launch guide, rehearsal). The demo history is marked demo,
every path that trades skips it, and a server started in demo mode runs and trades no agent at all.
A recording fake stands in for Alpaca, so any request at all would show."""
import os;
import from datetime { date, datetime }
import from action.fixtures { team }
import from dashboard.demo { DemoSim }
import from models.graph { Order, PortfolioMode, RunStatus, Sent }
import from run.agents { run_next_agent, tick_agents }
import from run.guard { NEW_YORK, daily_run }
import from run.switches { DEMO_ENV }
import from run.trading { team_trading_tick }
import from tests.fakes.broker_server { FakeBroker }
import from tests.runs.action_exit_run { deps_for }

glob TODAY: date = date(2026, 10, 22);
# Every point in a trading day where something could start a run or send an order: the morning
# run, the forward-test start, the 9:45 orders, a fill, the stop check, and the evening review.
glob TIMES: list[str] = ["07:30", "09:00", "09:45", "10:00", "12:00", "15:50", "16:30"];

def at(day: date, hhmm: str) -> datetime {
    return datetime.fromisoformat(f"{day.isoformat()}T{hhmm}:00").replace(tzinfo=NEW_YORK);
}

"""Every trading path, at every point of the day, on `portfolio`; returns the trading lines."""
def trade_all_day(fake: FakeBroker, portfolio: any) -> list[str] {
    lines: list[str] = [];
    deps = deps_for(fake);
    for hhmm in TIMES {
        now = at(TODAY, hhmm);
        lines.extend(team_trading_tick(portfolio, now, deps));
        lines.append(run_next_agent(now));
        tick_agents(now);
    }
    return [line for line in lines if line];
}

test "the demo history sends nothing to a broker at any point in the day" {
    portfolio = team(PortfolioMode.AUTO, 0.0);
    DemoSim(portfolio=portfolio, today=TODAY).run();
    seeded = len([o for o in [portfolio ->:Sent:->[?:Order]]]);
    assert portfolio.demo and seeded > 0;
    fake = FakeBroker(auto_fill=True);
    try {
        outcome = daily_run(portfolio, TODAY.isoformat());
        assert outcome.status == RunStatus.SKIPPED and "demo history" in outcome.note;
        assert trade_all_day(fake, portfolio) == [];
        assert fake.requests == [];
        assert len([o for o in [portfolio ->:Sent:->[?:Order]]]) == seeded;
    } finally {
        fake.stop();
    }
}

test "a server in demo mode runs and trades no agent, even one with real history" {
    portfolio = team(PortfolioMode.AUTO, 100000.0);
    assert not portfolio.demo;
    fake = FakeBroker(auto_fill=True);
    before = os.environ.get(DEMO_ENV);
    os.environ[DEMO_ENV] = "1";
    try {
        outcome = daily_run(portfolio, TODAY.isoformat());
        assert outcome.status == RunStatus.SKIPPED and DEMO_ENV in outcome.note;
        assert trade_all_day(fake, portfolio) == [];
        assert fake.requests == [];
    } finally {
        fake.stop();
        if before is None {
            os.environ.pop(DEMO_ENV, None);
        } else {
            os.environ[DEMO_ENV] = before;
        }
    }
}

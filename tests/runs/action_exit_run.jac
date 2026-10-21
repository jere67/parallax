"""Action exit run (#91): three consecutive trading days, October 21 to 23, 2026, simulated end
to end against the fake broker, which follows the order rules the spike verified.

The exit criterion is three consecutive days of paper trading with zero gate bypasses (TDD
§15). Until the team approves live trading, the days are simulated: each morning the Run Guard
runs the whole pipeline on the stubs in run/stubs.jac, and the trading tick then fires every
minute from 9:00 a.m. to 5:00 p.m. New York time on a fake clock, as the scheduled job does.
The market follows TAPE, and fills arrive as EVENTS say:

- Wednesday: the forward test starts at 9:00 from the flat account; the run buys AAPL, MSFT,
  and NVDA; MSFT fills only 10 shares, and the 3:50 cancel leaves it with a stop for those.
- Thursday: the run adds to MSFT (cancel its stop, buy, re-stop); NVDA falls through its stop.
- Friday: the time stops of AAPL and MSFT reach the run date, so both are sold, MSFT in two
  fills; NVDA, no longer held, is bought again.

The Orchestrator is scripted, so each morning run is a normal one. Every evening reconciles with the fake account, scores the votes whose windows closed, and
simulates the baselines. `jac test` runs this module's entry block, so writing the findings
waits for the flag:

    TRADING_AGENT_RUN_ACTION_EXIT=1 EXIT_OUT=/tmp/action-exit.json jac run --no-takeover tests/runs/action_exit_run.jac

Findings: docs/runs/.
"""
import json;
import os;
import from datetime { date, datetime, timedelta }
import from pathlib { Path }
import from action.baselines { FORWARD_TEST_ENV, baselines_of, sim_marks }
import from action.executor { MarketView, open_positions }
import from action.fixtures { broker_for, market, team }
import from action.reconcile { marks_of }
import from analysis.history { History, bar }
import from models.graph { Coverage, Covers, Decided, Decision, Order, PortfolioMode, Run, Sent, VoteRecord, Voted }
import from research.alpaca { Bar, MarketDay }
import from run.guard { NEW_YORK, RunSession, daily_run }
import from run.stubs { Stubs, calendar_day }
import from run.trading { TradingDeps, trading_tick }
import from tests.fakes.broker_server { FakeBroker }

glob RUN_ENV: str = "TRADING_AGENT_RUN_ACTION_EXIT";
glob DAYS: list[str] = ["2026-10-21", "2026-10-22", "2026-10-23"];
glob SYMBOLS: list[str] = ["AAPL", "MSFT", "NVDA"];
# Every specialist votes STRONG_BUY for two sessions, so each buy's time stop is two sessions out.
glob VOTE: str = json.dumps({"stance": "STRONG_BUY", "confidence": 0.9, "horizon_days": 2, "rationale": "Strong.", "cited_evidence": [1]});
# Each session's open, low, and close by symbol. The day before the first gives prior closes.
glob TAPE: dict[str, dict[str, tuple[float, float, float]]] = {
    "2026-10-20": {"AAPL": (200.0, 200.0, 200.0), "MSFT": (200.0, 200.0, 200.0), "NVDA": (200.0, 200.0, 200.0), "SPY": (500.0, 500.0, 500.0)},
    "2026-10-21": {"AAPL": (200.0, 199.0, 202.0), "MSFT": (200.0, 198.0, 199.0), "NVDA": (200.0, 199.0, 205.0), "SPY": (500.0, 499.0, 502.0)},
    "2026-10-22": {"AAPL": (203.0, 201.0, 204.0), "MSFT": (199.0, 197.0, 200.0), "NVDA": (205.0, 188.0, 189.0), "SPY": (502.0, 497.0, 498.0)},
    "2026-10-23": {"AAPL": (204.0, 203.0, 206.0), "MSFT": (200.0, 199.0, 201.0), "NVDA": (189.0, 187.0, 190.0), "SPY": (498.0, 497.0, 503.0)}
};
# Fills by session and New York time: client order ID, shares (0 for all left), and price.
glob FILLS: dict[str, dict[str, list[tuple[str, int, float]]]] = {
    "2026-10-21": {"09:46": [("2026-10-21-AAPL-entry", 0, 200.2), ("2026-10-21-NVDA-entry", 0, 200.4), ("2026-10-21-MSFT-entry", 10, 200.3)]},
    "2026-10-22": {"09:46": [("2026-10-22-MSFT-add", 0, 199.2)]},
    "2026-10-23": {
        "09:46": [("2026-10-23-AAPL-exit", 0, 203.8), ("2026-10-23-MSFT-exit", 20, 199.6), ("2026-10-23-NVDA-entry", 0, 189.5)],
        "10:00": [("2026-10-23-MSFT-exit", 0, 199.8)]
    }
};
# Prices printed during a session besides its open (9:30), low (12:00), and close (4:00).
glob PRINTS: dict[str, dict[str, list[tuple[str, float]]]] = {
    "2026-10-22": {"11:00": [("NVDA", 191.0)]}
};

"""One simulated session as the record and the account saw it."""
obj DayResult {
    has day: str,
        run_status: str,
        decisions: dict[str, str],
        log: list[str],
        equity: float,
        drawdown: float,
        drift: list[str],
        bypasses: list[str],
        record: dict[str, int],
        account: dict[str, int];

    def clean -> bool {
        return not self.drift and not self.bypasses and self.record == self.account;
    }

    def json_of -> dict[str, object] {
        return {"day": self.day, "run_status": self.run_status, "decisions": self.decisions, "log": self.log, "equity": self.equity, "drawdown": self.drawdown, "drift": self.drift, "bypasses": self.bypasses, "record": self.record, "account": self.account};
    }
}

obj ExitRun {
    has days: list[DayResult] = [],
        orders: list[str] = [],
        votes_scored: int = 0,
        votes_total: int = 0,
        baselines: dict[str, list[str]] = {},
        baseline_equity: dict[str, dict[str, float]] = {};

    def passed -> bool {
        return len(self.days) == len(DAYS) and all(d.clean() for d in self.days);
    }

    def json_of -> dict[str, object] {
        return {"passed": self.passed(), "days": [d.json_of() for d in self.days], "orders": self.orders, "votes_scored": self.votes_scored, "votes_total": self.votes_total, "baselines": self.baselines, "baseline_equity": self.baseline_equity};
    }
}

def ny(day: str, hhmm: str) -> datetime {
    return datetime.fromisoformat(f"{day}T{hhmm}:00").replace(tzinfo=NEW_YORK);
}

def weekdays(start: str, end: str) -> list[str] {
    first = date.fromisoformat(start);
    found = [first + timedelta(days=i) for i in range((date.fromisoformat(end) - first).days + 1)];
    return [d.isoformat() for d in found if d.weekday() < 5];
}

def tape_bars(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
    found: dict[str, dict[str, Bar]] = {};
    for (day, row) in TAPE.items() {
        for s in symbols {
            if s in row and start <= day <= end {
                (o, low, c) = row[s];
                found.setdefault(s, {})[day] = bar(day, c, open=o, low=low);
            }
        }
    }
    return found;
}

def deps_for(fake: FakeBroker) -> TradingDeps {
    def view(_tickers: list[str]) -> MarketView {
        return market(dict(fake.prices), datetime.fromisoformat(fake.now));
    }
    def calendar(day: str) -> MarketDay | None {
        return calendar_day(day) if date.fromisoformat(day).weekday() < 5 else None;
    }
    return TradingDeps(broker=broker_for(fake), view=view, calendar=calendar, history=History(bars=tape_bars, sessions=weekdays));
}

"""What the market does at `hhmm`: the open at 9:30, the low at noon, the close at 4:00 (when
unfilled DAY orders end), and any other print or fill the session scripts."""
def market_events(fake: FakeBroker, day: str, hhmm: str) {
    row = TAPE[day];
    if hhmm in ("09:30", "12:00", "16:00") {
        at = {"09:30": 0, "12:00": 1, "16:00": 2}[hhmm];
        for (s, prices) in row.items() {
            fake.set_price(s, prices[at]);
        }
    }
    for (s, price) in PRINTS.get(day, {}).get(hhmm, []) {
        fake.set_price(s, price);
    }
    for (ref, qty, price) in FILLS.get(day, {}).get(hhmm, []) {
        fake.fill(ref, qty, price);
    }
    if hhmm == "16:00" {
        fake.close_session();
    }
}

"""The Orchestrator, scripted: research every ticker, convene the panel, submit, summarize."""
def driver(s: RunSession) -> str {
    s.get_run_context();
    s.dispatch_research(s.tickers(), ["market", "fundamentals", "news"]);
    s.convene_panel(s.tickers());
    s.submit_decisions("All covered.");
    s.write_run_summary("Decided every covered ticker on a strong panel.");
    return "done";
}

def decisions_of(run: Run) -> dict[str, str] {
    found: dict[str, str] = {};
    for cov in [run ->:Covers:->[?:Coverage]] {
        for d in [cov ->:Decided:->[?:Decision]] {
            found[cov.ticker] = d.action.value;
        }
    }
    return found;
}

"""Simulate the three sessions on a fresh fake account and a fresh team portfolio."""
def exit_run -> ExitRun {
    found = ExitRun();
    fake = FakeBroker(now=ny(DAYS[0], "07:00").isoformat());
    saved = os.environ.get(FORWARD_TEST_ENV);
    os.environ[FORWARD_TEST_ENV] = DAYS[0];
    try {
        deps = deps_for(fake);
        portfolio = team(PortfolioMode.INSIGHT, 0.0);
        for day in DAYS {
            stubs = Stubs(symbols=SYMBOLS, vote=VOTE);
            stubs.install();
            try {
                outcome = daily_run(portfolio, day, driver);
            } finally {
                stubs.restore();
            }
            log: list[str] = [];
            for minute in range(9 * 60, 17 * 60 + 1) {
                hhmm = f"{minute // 60:02d}:{minute % 60:02d}";
                when = ny(day, hhmm);
                fake.now = when.isoformat();
                market_events(fake, day, hhmm);
                log.extend(f"{hhmm} {line}" for line in trading_tick(portfolio, when, deps));
            }
            mark = marks_of(portfolio)[day];
            run = outcome.run;
            found.days.append(DayResult(
                day=day,
                run_status=outcome.status.value,
                decisions=decisions_of(run) if run is not None else {},
                log=log,
                equity=mark.equity,
                drawdown=mark.drawdown,
                drift=mark.drift,
                bypasses=mark.bypasses,
                record={t: p.qty for (t, p) in sorted(open_positions(portfolio).items())},
                account={s: p.qty for (s, p) in sorted(fake.positions.items()) if p.qty != 0}
            ));
        }
        found.orders = [f"{o.client_order_id}: {o.side.value} {o.qty} {o.order_type}, {o.status}, {o.filled_qty} filled" for o in [portfolio ->:Sent:->[?:Order]]];
        votes = [v for r in [portfolio -->[?:Run]] for c in [r ->:Covers:->[?:Coverage]] for v in [c ->:Voted:->[?:VoteRecord]]];
        found.votes_total = len(votes);
        found.votes_scored = len([v for v in votes if v.excess_return is not None]);
        for (kind, b) in baselines_of(portfolio).items() {
            found.baselines[kind.value] = b.trade_log;
            found.baseline_equity[kind.value] = {d: m.equity for (d, m) in sorted(sim_marks(b).items())};
        }
    } finally {
        if saved is None {
            os.environ.pop(FORWARD_TEST_ENV, None);
        } else {
            os.environ[FORWARD_TEST_ENV] = saved;
        }
        fake.stop();
    }
    return found;
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        result = exit_run();
        Path(os.environ.get("EXIT_OUT", "action-exit.json")).write_text(json.dumps(result.json_of(), indent=1));
    }
}

"""Forward-test baselines (TDD §13, forward paper test; GAP-09): two portfolios simulated from
daily bars beside the team account, from the same start day and starting balance.

- **Equal-weight shortlist.** Every stock the morning screen shortlists is a BUY at conviction
  1 (an ADD when already held), through the team's sizing and risk gate, so the gap to the
  full system is what the agents add. Orders fill at the session's open. A buy's stop sits
  the gate's stop distance below its fill and fires when a session's low reaches it, filling
  at the stop or at a lower open. A position is sold at the open of the session its time stop
  reaches, ten sessions after it was bought (run/analysis.jac, DEFAULT_HORIZON_DAYS), unless
  the screen picks it again that morning, which renews the time stop.
- **SPY buy-and-hold.** The whole balance buys SPY at the first session's open and holds,
  fully invested and outside the gate: it is the market, not a strategy.

Both mark to each session's close. A session is simulated once its bars are final
(research/alpaca.jac, BARS_FINAL_AT), so the evening tick simulates through the previous
session; a missed evening is caught up the next.

`start_forward_test` starts all three portfolios: it records the team account's equity as
the starting balance, puts the team portfolio in auto mode, and creates both baselines. It
runs only on the operator's go-ahead, given by setting FORWARD_TEST_ENV to the start date.
"""
import math;
import os;
import from datetime { date, datetime, timedelta }
import from action.broker { Broker }
import from action.executor { run_regime }
import from action.gate { Book, BookPosition, GateConfig, Instrument, Proposal, check_orders }
import from action.sizing { SizingCandidate, SizingConfig, size_positions }
import from analysis.history { History }
import from analysis.scoring { BENCHMARK }
import from models.graph {
    Baseline,
    BaselineKind,
    Benchmarks,
    Coverage,
    CoverageReason,
    Covers,
    DailyMark,
    OrderSide,
    Portfolio,
    PortfolioMode,
    Position,
    Ran,
    Run,
    RunStatus,
    SimHolds,
    SimMarked,
    TradeAction
}
import from research.alpaca { Bar, bars_final }
import from run.analysis { DEFAULT_HORIZON_DAYS, trading_day_after }
import from run.public { public }

# Set to the trading date the forward test starts; the first tick that morning starts it.
glob FORWARD_TEST_ENV: str = "TRADING_AGENT_FORWARD_TEST_START";
# Calendar days of bars read before the first session simulated, so a stock with no bar on a
# session is still marked at its last close.
glob LOOKBACK_DAYS: int = 14;
# Sessions read past today, so a time stop counts real holidays.
glob CALENDAR_AHEAD_DAYS: int = 45;
glob MAX_TRADE_LOG_LINES: int = 2000;

"""The trading date in FORWARD_TEST_ENV, or "" when the operator has not set one."""
def forward_test_day -> str {
    found = os.environ.get(FORWARD_TEST_ENV, "").strip();
    if found {
        date.fromisoformat(found);
    }
    return found;
}

def baselines_of(portfolio: Portfolio) -> dict[BaselineKind, Baseline] {
    return {b.kind: b for b in [portfolio ->:Benchmarks:->[?:Baseline]]};
}

def sim_positions(baseline: Baseline) -> dict[str, Position] {
    return {p.ticker: p for p in [baseline ->:SimHolds:->[?:Position]] if p.open()};
}

def sim_marks(baseline: Baseline) -> dict[str, DailyMark] {
    return {m.day: m for m in [baseline ->:SimMarked:->[?:DailyMark]]};
}

"""The stocks `run`'s screen shortlisted, by ticker, or none when the run did not finish."""
def shortlist(run: Run | None) -> dict[str, Coverage] {
    if run is None or run.status in (RunStatus.RUNNING, RunStatus.SKIPPED) {
        return {};
    }
    return {c.ticker: c for c in [run ->:Covers:->[?:Coverage]] if c.reason == CoverageReason.SCREEN};
}

"""Start the forward test on `day`: the team account's equity becomes the starting balance of
all three portfolios, the team portfolio trades from today's run, and both baselines start
in cash. The account must be flat, so all three start alike."""
def start_forward_test(portfolio: Portfolio, broker: Broker, now: datetime, day: str) -> str {
    if baselines_of(portfolio) {
        raise ValueError("the forward test has already started");
    }
    account = broker.account();
    held = [s for (s, p) in broker.positions().items() if p.qty != 0];
    working = broker.orders("open");
    if held or working {
        raise ValueError(f"the paper account must be flat to start the forward test: {len(held)} positions ({', '.join(sorted(held))}) and {len(working)} open orders");
    }
    equity = account.equity;
    portfolio.starting_cash = equity;
    portfolio.opened_at = now.isoformat();
    portfolio.peak_equity = equity;
    portfolio.mode = PortfolioMode.AUTO;
    for kind in [BaselineKind.EQUAL_WEIGHT, BaselineKind.SPY] {
        public(portfolio +>:Benchmarks:+> Baseline(kind=kind, starting_cash=equity, start_day=day, cash=equity, peak_equity=equity));
    }
    return f"forward test started on {day}: starting balance {equity:,.2f}, team portfolio in auto mode, baselines {BaselineKind.EQUAL_WEIGHT.value} and {BaselineKind.SPY.value} created";
}

"""One session being simulated: its date, the bars around it, the trading sessions for time
stops, and when the simulation ran."""
obj SimDay {
    has day: str,
        bars: dict[str, dict[str, Bar]],
        sessions: list[str],
        now: datetime;

    def bar(ticker: str) -> Bar | None {
        return self.bars.get(ticker, {}).get(self.day);
    }

    """The close of `ticker` on this session, or its last close before, or `fallback`."""
    def last_close(ticker: str, fallback: float) -> float {
        found = self.bars.get(ticker, {});
        earlier = sorted(d for d in found if d <= self.day);
        return found[earlier[-1]].close if earlier else fallback;
    }
}

"""A simulated buy: `qty` shares at `price`, its stop `stop_distance` below, and its time stop."""
obj SimBuy {
    has ticker: str,
        qty: int,
        price: float;
    has sector: str = "",
        stop_distance: float = 0.0,
        time_stop: str = "";
}

"""Simulate every baseline of `portfolio` through the last session whose bars are final at
`now`, and return what each session did."""
def advance_baselines(
    portfolio: Portfolio,
    now: datetime,
    history: History = History(),
    sizing: SizingConfig = SizingConfig(),
    gate: GateConfig = GateConfig()
) -> list[str] {
    found = baselines_of(portfolio);
    if not found {
        return [];
    }
    first = min(b.start_day for b in found.values());
    today = now.date();
    sessions = history.read_sessions((date.fromisoformat(first) - timedelta(days=LOOKBACK_DAYS)).isoformat(), (today + timedelta(days=CALENDAR_AHEAD_DAYS)).isoformat());
    final = [s for s in sessions if bars_final(s, now)];
    pending = {k: [s for s in final if s >= b.start_day and s > b.simulated_through] for (k, b) in found.items()};
    days = sorted({s for due in pending.values() for s in due});
    if not days {
        return [];
    }
    runs = {r.run_date: r for r in [portfolio ->:Ran:->[?:Run]]};
    tickers = {BENCHMARK};
    for b in found.values() {
        tickers |= set(sim_positions(b));
    }
    for d in days {
        tickers |= set(shortlist(runs.get(d)));
    }
    bars = history.read_bars(sorted(tickers), (date.fromisoformat(days[0]) - timedelta(days=LOOKBACK_DAYS)).isoformat(), days[-1]);
    lines: list[str] = [];
    for (kind, b) in sorted(found.items(), key=lambda (kv: tuple[BaselineKind, Baseline]) { kv[0].value; }) {
        for d in pending[kind] {
            at = SimDay(day=d, bars=bars, sessions=sessions, now=now);
            if kind == BaselineKind.SPY {
                done = simulate_spy(b, at);
            } else {
                done = simulate_equal_weight(b, at, runs.get(d), sizing, gate);
            }
            b.trade_log = (b.trade_log + done)[-MAX_TRADE_LOG_LINES:];
            lines.extend(f"{kind.value} {line}" for line in done);
        }
    }
    return lines;
}

"""One session of the equal-weight shortlist: trade at the open, run the stops on the day's
range, and mark at the close."""
def simulate_equal_weight(baseline: Baseline, at: SimDay, run: Run | None, sizing: SizingConfig = SizingConfig(), gate: GateConfig = GateConfig()) -> list[str] {
    lines: list[str] = [];
    day = at.day;
    held = sim_positions(baseline);
    picks = shortlist(run);
    renewed = trading_day_after(at.sessions, day, DEFAULT_HORIZON_DAYS);
    opens: dict[str, float] = {};
    for t in set(held) | set(picks) {
        found = at.bar(t);
        if found is not None {
            opens[t] = found.open;
        }
    }

    candidates: list[SizingCandidate] = [];
    for (t, p) in sorted(held.items()) {
        picked = t in picks;
        expired = bool(p.time_stop) and p.time_stop <= day and not picked;
        candidates.append(SizingCandidate(
            ticker=t,
            action=TradeAction.SELL if expired else (TradeAction.ADD if picked else TradeAction.HOLD),
            conviction=1.0 if picked else 0.0,
            price=opens.get(t) or at.last_close(t, p.avg_entry_price),
            realized_vol_20=picks[t].realized_vol_20 if picked else None,
            current_qty=p.qty
        ));
        if picked {
            p.time_stop = renewed;
        }
    }
    for (t, cov) in sorted(picks.items()) {
        if t not in held {
            candidates.append(SizingCandidate(ticker=t, action=TradeAction.BUY, conviction=1.0, price=opens.get(t, 0.0), realized_vol_20=cov.realized_vol_20));
        }
    }

    if candidates {
        equity = baseline.cash + sum(c.current_qty * c.price for c in candidates);
        plan = size_positions(candidates, equity, sizing);
        proposals = [
            Proposal(ticker=p.ticker, action=c.action, side=p.side, qty=abs(p.share_delta), conviction=c.conviction)
            for (p, c) in zip(plan.positions, candidates)
            if p.side is not None and p.share_delta != 0
        ];
        def sector_of(t: str) -> str {
            return picks[t].sector if t in picks else held[t].sector;
        }
        instruments = {
            c.ticker: Instrument(
                ticker=c.ticker,
                price=opens.get(c.ticker, 0.0),
                sector=sector_of(c.ticker),
                tradable=c.ticker in opens,
                trade_age_minutes=0.0,
                atr_14=picks[c.ticker].atr_14 if c.ticker in picks else None,
                volume_20=picks[c.ticker].volume_20 if c.ticker in picks else None,
                sessions_to_earnings=picks[c.ticker].sessions_to_earnings if c.ticker in picks else None
            )
            for c in candidates
        };
        book = Book(
            equity=equity,
            peak_equity=max(baseline.peak_equity, equity),
            positions={c.ticker: BookPosition(ticker=c.ticker, qty=c.current_qty, price=c.price, sector=sector_of(c.ticker)) for c in candidates if c.current_qty > 0}
        );
        results = check_orders(proposals, book, instruments, run_regime(run) if run is not None else None, gate);
        for r in [r for r in results if r.side == OrderSide.SELL] + [r for r in results if r.side == OrderSide.BUY] {
            if r.approved_qty <= 0 {
                lines.append(f"{day} {r.ticker} {r.side.value} {r.requested_qty}: refused by {r.rejected_by()}");
            } elif r.side == OrderSide.SELL {
                lines.append(sell(baseline, held[r.ticker], r.approved_qty, opens[r.ticker], day, "time stop"));
            } else {
                lines.append(buy(baseline, SimBuy(ticker=r.ticker, qty=r.approved_qty, price=opens[r.ticker], sector=sector_of(r.ticker), stop_distance=r.stop_distance, time_stop=renewed), day));
            }
        }
    }

    for (t, p) in sorted(sim_positions(baseline).items()) {
        found = at.bar(t);
        if found is not None and p.stop_price > 0.0 and found.low <= p.stop_price {
            lines.append(sell(baseline, p, p.qty, min(found.open, p.stop_price), day, "stop"));
        }
    }
    lines.append(mark(baseline, at));
    return lines;
}

"""One session of SPY buy-and-hold: buy with the whole balance at the first open, then mark."""
def simulate_spy(baseline: Baseline, at: SimDay) -> list[str] {
    lines: list[str] = [];
    found = at.bar(BENCHMARK);
    if not sim_positions(baseline) and found is not None {
        qty = int(math.floor(baseline.cash / found.open));
        if qty > 0 {
            lines.append(buy(baseline, SimBuy(ticker=BENCHMARK, qty=qty, price=found.open), at.day));
        }
    }
    lines.append(mark(baseline, at));
    return lines;
}

"""Fill `order`. An add averages the entry and never lowers the stop."""
def buy(baseline: Baseline, order: SimBuy, day: str) -> str {
    baseline.cash -= order.qty * order.price;
    stop = order.price - order.stop_distance if order.stop_distance > 0.0 else 0.0;
    position = sim_positions(baseline).get(order.ticker);
    if position is None {
        public(baseline +>:SimHolds:+> Position(ticker=order.ticker, sector=order.sector, qty=order.qty, avg_entry_price=order.price, opened_at=day, stop_price=stop, time_stop=order.time_stop));
        return f"{day} {order.ticker} bought {order.qty} at {order.price:.2f}" + (f", stop {stop:.2f}" if stop > 0.0 else "");
    }
    position.avg_entry_price = (position.avg_entry_price * position.qty + order.price * order.qty) / (position.qty + order.qty);
    position.qty += order.qty;
    position.stop_price = max(position.stop_price, stop);
    return f"{day} {order.ticker} added {order.qty} at {order.price:.2f}, now {position.qty}, stop {position.stop_price:.2f}";
}

def sell(baseline: Baseline, position: Position, qty: int, price: float, day: str, reason: str) -> str {
    baseline.cash += qty * price;
    position.qty -= qty;
    if position.qty <= 0 {
        position.qty = 0;
        position.closed_at = day;
        position.exit_price = price;
    }
    return f"{day} {position.ticker} sold {qty} at {price:.2f} ({reason})";
}

"""Mark `baseline` at the session's close and move its peak."""
def mark(baseline: Baseline, at: SimDay) -> str {
    day = at.day;
    held = sim_positions(baseline);
    value = sum(p.qty * at.last_close(t, p.avg_entry_price) for (t, p) in held.items());
    equity = baseline.cash + value;
    baseline.peak_equity = max(baseline.peak_equity, equity);
    drawdown = 1.0 - equity / baseline.peak_equity if baseline.peak_equity > 0.0 else 0.0;
    public(baseline +>:SimMarked:+> DailyMark(day=day, equity=equity, cash=baseline.cash, positions_value=value, peak_equity=baseline.peak_equity, marked_at=at.now.isoformat(), drawdown=drawdown, open_positions=len(held)));
    baseline.simulated_through = day;
    return f"{day} marked {equity:,.2f} ({len(held)} positions, drawdown {drawdown:.1%})";
}

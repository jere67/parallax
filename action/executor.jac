"""The executor (TDD §8, execution on Alpaca; FR-10): the run's decisions become sized, gated,
paper orders, and every held position keeps a protective stop.

Three entry points, each safe to call again:

- `execute_run` sizes the run's decisions against the account, runs them through the risk
  gate, records a RiskCheck per order, and submits the approved ones as marketable limit
  orders (DAY, latest trade ±0.3%), sells first. It runs once per run.
- `sync_orders` refreshes every working order from Alpaca, records each new fill, and moves
  positions with them.
- `keep_stops` makes sure every open position has exactly one working GTC stop for all its
  shares. It waits while a buy or sell on the stock is working, since Alpaca refuses an
  order whose opposite side is open (wash-trade protection) and a working sell reserves the
  shares (order-rule spike, #13). So a stop follows a fill, an add, a trim, a partial fill
  once its buy is canceled at 3:50, and a GTC stop that expired after 90 days.

Orders exist only as RiskCheck approvals or as a position's protective stop: `submit` takes a
RiskCheck and refuses one that did not approve the quantity, and stops are placed only for a
position (TDD §14, an agent tries to trade outside limits). Every order also hangs off the
portfolio (`Sent`), so reconciliation can trace each one.

Everything here runs on the job's own thread, never on a worker thread, since it writes the
graph (TDD §3, rule 6).

Coins (research/crypto.jac) go through the same steps. They trade around the clock and Alpaca
takes no DAY order for them, so a coin's entry is a GTC limit that the 3:50 window cancels like a
DAY order, and its stop is a GTC stop-limit (Alpaca has no plain stop for crypto) 1% under the
stop price. Quantities are fractions down to the coin's trade increment. Option contracts are
left to action/options.jac: nothing here sizes, gates, or stops them, but their value still
counts toward gross exposure.
"""
import math;
import os;
import from datetime { datetime }
import from action.broker { Broker, BrokerError, BrokerOrder, BrokerPosition, OrderRequest }
import from action.gate { GATE_VERSION, Book, BookPosition, GateConfig, GateResult, Instrument, Proposal, breaker_peak, check_orders }
import from action.sizing { SizingCandidate, SizingConfig, size_positions }
import from models.assets { CRYPTO, OPTIONS, STOCKS, asset_class_of }
import from models.graph {
    CheckedBy,
    Coverage,
    DailyMark,
    Covers,
    Decided,
    Decision,
    FilledBy,
    Fill,
    HasMacro,
    Holds,
    MacroRecord,
    Marked,
    OpenedBy,
    Order,
    OrderPurpose,
    OrderSide,
    Placed,
    Portfolio,
    PortfolioMode,
    Position,
    RiskCheck,
    Run,
    RunStatus,
    Sent,
    StoppedBy,
    TradeAction
}
import from models.research { RegimeInputs }
import from research.alpaca { Asset, LatestTrade, assets, latest_trades }
import from research.collector { parse_utc, run_budget }
import from research.crypto { CryptoAsset, crypto_assets, crypto_latest_trades, is_crypto }
import from run.public { public }

# Marketable limit offset from the latest trade (TDD §8, order type).
glob LIMIT_OFFSET: float = 0.003;
# Set to 1 to stop every order: the executor still sizes and gates, records why nothing was
# sent, and places no stop (TDD §2, principle 6).
glob ORDERS_OFF_ENV: str = "TRADING_AGENT_DISABLE_ORDERS";
# Alpaca order states in which an order may still fill (action/broker.jac).
glob FINISHED_STATUSES: set[str] = {"filled", "canceled", "expired", "replaced", "rejected"};
# A coin's stop-limit sells no lower than this far under its stop price.
glob CRYPTO_STOP_SLIPPAGE: float = 0.01;
# A coin position left with less than this share of what it held before an exit is closed: Alpaca
# takes its fee in the coin, so an exit can leave dust the account cannot sell.
glob DUST_FRACTION: float = 0.02;

def orders_disabled -> bool {
    return os.environ.get(ORDERS_OFF_ENV, "").strip() == "1";
}

"""The latest trade and tradability of each stock and coin, from Alpaca's data and asset APIs. A
test passes one in instead of calling the network."""
obj MarketView {
    has trades: dict[str, LatestTrade] = {},
        assets: dict[str, Asset] = {},
        gaps: list[str] = [],
        coins: dict[str, CryptoAsset] = {};

    """The smallest quantity `ticker` trades in: a share, or the coin's trade increment."""
    def increment(ticker: str) -> float {
        found = self.coins.get(ticker);
        return found.min_trade_increment if found is not None and found.min_trade_increment > 0.0 else 1.0;
    }

    """A coin's price tick, or 0 for a stock, whose tick follows from its price."""
    def price_increment(ticker: str) -> float {
        found = self.coins.get(ticker);
        return found.price_increment if found is not None else 0.0;
    }

    def price(ticker: str) -> float | None {
        found = self.trades.get(ticker);
        return found.price if found is not None else None;
    }

    """Minutes since the latest trade, or None when there is none."""
    def trade_age(ticker: str, now: datetime) -> float | None {
        found = self.trades.get(ticker);
        if found is None {
            return None;
        }
        try {
            return max(0.0, (now - parse_utc(found.at)).total_seconds() / 60.0);
        } except ValueError {
            return None;
        }
    }
}

"""Read the latest trades and the asset list for `tickers`. A failed read becomes a gap, and
the gate then refuses the buys it cannot judge."""
def market_view(tickers: list[str]) -> MarketView {
    view = MarketView();
    budget = run_budget();
    stocks = [t for t in tickers if asset_class_of(t) == STOCKS];
    coins = [t for t in tickers if is_crypto(t)];
    if stocks {
        try {
            (found, gaps) = latest_trades(stocks, budget);
            view.trades = {t.symbol: t for t in found};
            view.gaps.extend(gaps);
        } except Exception as e {
            view.gaps.append(f"alpaca.latest_trade: unavailable ({type(e).__name__}: {str(e)[:200]})");
        }
        try {
            listed = assets(budget);
            view.assets = {t: listed[t] for t in stocks if t in listed};
        } except Exception as e {
            view.gaps.append(f"alpaca.assets: unavailable ({type(e).__name__}: {str(e)[:200]})");
        }
    }
    if coins {
        try {
            (found, gaps) = crypto_latest_trades(coins, budget);
            view.trades.update({t.symbol: t for t in found});
            view.gaps.extend(gaps);
        } except Exception as e {
            view.gaps.append(f"alpaca.crypto_trade: unavailable ({type(e).__name__}: {str(e)[:200]})");
        }
        try {
            pairs = crypto_assets(budget);
            view.coins = {t: pairs[t] for t in coins if t in pairs};
        } except Exception as e {
            view.gaps.append(f"alpaca.crypto_assets: unavailable ({type(e).__name__}: {str(e)[:200]})");
        }
    }
    return view;
}

"""True when `classes` (a run's) let its agent buy `ticker`."""
def class_enabled(ticker: str, classes: list[str]) -> bool {
    return asset_class_of(ticker) in classes;
}

"""What one call did, for the job's log and the run's execution note."""
obj ExecutionReport {
    has done: list[str] = [],
        refused: list[str] = [],
        note: str = "";

    def line -> str {
        parts = [self.note] if self.note else [];
        parts.extend(self.done + [f"refused: {r}" for r in self.refused]);
        return "; ".join(parts);
    }
}

"""Each covered ticker's coverage and decision in `run`."""
def decisions_of(run: Run) -> dict[str, tuple[Coverage, Decision]] {
    found: dict[str, tuple[Coverage, Decision]] = {};
    for cov in [run ->:Covers:->[?:Coverage]] {
        for d in [cov ->:Decided:->[?:Decision]] {
            found[cov.ticker] = (cov, d);
        }
    }
    return found;
}

"""The portfolio's open stock and coin positions by ticker, or its options too with `options`."""
def open_positions(portfolio: Portfolio, options: bool = False) -> dict[str, Position] {
    return {p.ticker: p for p in [portfolio ->:Holds:->[?:Position]] if p.open() and (options or p.asset_class != OPTIONS)};
}

"""The equity the drawdown breaker measures `portfolio` from under `gate`: its highest close
since it started, within the gate's window."""
def breaker_peak_of(portfolio: Portfolio, gate: GateConfig) -> float {
    since = portfolio.opened_at[:10];
    marks = sorted([m for m in [portfolio ->:Marked:->[?:DailyMark]] if m.day >= since and m.equity > 0.0], key=lambda (m: DailyMark) { m.day; });
    return breaker_peak(portfolio.starting_cash, [m.equity for m in marks], gate.drawdown_window);
}

"""Every order the portfolio sent that may still change."""
def working_orders(portfolio: Portfolio) -> list[Order] {
    return [o for o in [portfolio ->:Sent:->[?:Order]] if o.status not in FINISHED_STATUSES and o.alpaca_order_id];
}

def run_regime(run: Run) -> RegimeInputs | None {
    for m in [run ->:HasMacro:->[?:MacroRecord]] {
        return m.inputs;
    }
    return None;
}

"""Size, gate, and submit `run`'s decisions on `portfolio`'s paper account, once. Records a
RiskCheck for every order the sizing proposed, approved or not, under its decision, and an
Order for each one sent. `view` replaces the network read of prices and assets."""
def execute_run(
    portfolio: Portfolio,
    run: Run,
    broker: Broker,
    now: datetime,
    view: MarketView | None = None,
    sizing: SizingConfig = SizingConfig(),
    gate: GateConfig = GateConfig()
) -> ExecutionReport {
    report_ = ExecutionReport();
    if run.executed_at {
        report_.note = f"already executed at {run.executed_at}";
        return report_;
    }
    if portfolio.mode != PortfolioMode.AUTO {
        report_.note = "insight mode: decisions are published, not traded";
        return report_;
    }
    if run.status in (RunStatus.RUNNING, RunStatus.SKIPPED) {
        report_.note = f"run is {run.status.value}; nothing to execute";
        return report_;
    }
    run.executed_at = now.isoformat();
    account = broker.account();
    every = broker.positions();
    held = {t: p for (t, p) in every.items() if p.qty > 0 and p.asset_class != OPTIONS};
    # Options are action/options.jac's, but their value still counts toward gross exposure.
    other_value = sum(abs(p.market_value) for p in every.values() if p.asset_class == OPTIONS);
    decided = decisions_of(run);
    tickers = sorted(set(decided) | set(held));
    seen = view or market_view(tickers);
    positions = open_positions(portfolio);

    candidates: list[SizingCandidate] = [];
    for t in tickers {
        pair = decided.get(t);
        cov = pair[0] if pair is not None else None;
        d = pair[1] if pair is not None else None;
        price = seen.price(t) or (held[t].current_price if t in held else 0.0);
        candidates.append(SizingCandidate(
            ticker=t,
            action=d.action if d is not None else TradeAction.HOLD,
            conviction=min(1.0, max(0.0, d.conviction)) if d is not None else 0.0,
            price=price,
            realized_vol_20=cov.realized_vol_20 if cov is not None else None,
            current_qty=held[t].qty if t in held else 0,
            increment=seen.increment(t)
        ));
    }
    plan = size_positions(candidates, account.equity, sizing);
    proposals = [
        Proposal(ticker=p.ticker, action=c.action, side=p.side, qty=abs(p.share_delta), conviction=c.conviction)
        for (p, c) in zip(plan.positions, candidates)
        if p.side is not None and p.share_delta != 0
    ];

    def sector_of(t: str) -> str {
        if t in decided {
            return decided[t][0].sector;
        }
        return positions[t].sector if t in positions else "";
    }
    instruments: dict[str, Instrument] = {};
    for t in tickers {
        asset = seen.assets.get(t);
        coin = seen.coins.get(t);
        cov = decided[t][0] if t in decided else None;
        listed = coin.tradable if coin is not None else asset.tradable if asset is not None else None;
        instruments[t] = Instrument(
            ticker=t,
            price=seen.price(t) or 0.0,
            sector=sector_of(t),
            # With no asset list, a held stock may still be sold; a buy is refused.
            tradable=listed if listed is not None else t in held,
            trade_age_minutes=seen.trade_age(t, now),
            atr_14=cov.atr_14 if cov is not None else None,
            volume_20=cov.volume_20 if cov is not None else None,
            sessions_to_earnings=cov.sessions_to_earnings if cov is not None else None,
            increment=seen.increment(t),
            min_qty=coin.min_order_size if coin is not None else 0.0,
            crypto=is_crypto(t),
            enabled=class_enabled(t, run.asset_classes)
        );
    }
    book = Book(
        equity=account.equity,
        peak_equity=max(breaker_peak_of(portfolio, gate), account.equity),
        positions={t: BookPosition(ticker=t, qty=p.qty, price=instruments[t].price or p.current_price, sector=sector_of(t)) for (t, p) in held.items()},
        other_value=other_value
    );
    results = check_orders(proposals, book, instruments, run_regime(run), gate);

    checks: list[tuple[RiskCheck, GateResult]] = [];
    for r in results {
        rc = RiskCheck(
            outcome=r.outcome(),
            approved_qty=r.approved_qty,
            checked_at=now.isoformat(),
            rules=r.rules,
            ticker=r.ticker,
            side=r.side,
            purpose=r.purpose,
            requested_qty=r.requested_qty,
            price=r.price,
            stop_distance=r.stop_distance,
            gate_version=GATE_VERSION,
            asset_class=asset_class_of(r.ticker)
        );
        if r.ticker in decided {
            public(decided[r.ticker][1] +>:CheckedBy():+> rc);
        } else {
            # A held stock the run did not cover still needs its check on record.
            public(portfolio ++> rc);
        }
        checks.append((rc, r));
        if r.approved_qty <= 0 {
            report_.refused.append(f"{r.ticker} {r.side.value} {r.requested_qty:g}: {r.rejected_by()}");
        }
    }
    if orders_disabled() {
        report_.note = f"orders are disabled ({ORDERS_OFF_ENV}=1); {len(checks)} checks recorded, nothing sent";
        run.execution_note = report_.line();
        return report_;
    }
    # Sells first, so exits free their cash and turnover before any buy is placed.
    ordered = [c for c in checks if c[1].side == OrderSide.SELL] + [c for c in checks if c[1].side == OrderSide.BUY];
    for (rc, r) in ordered {
        if r.approved_qty > 0 {
            report_.done.append(submit(portfolio, rc, broker, now, run.run_date, positions.get(r.ticker), seen.price_increment(r.ticker)));
        }
    }
    report_.note = f"{len(checks)} checks, {len([c for c in checks if c[1].approved_qty > 0])} approved";
    if seen.gaps {
        report_.note += f"; market data gaps: {'; '.join(seen.gaps)[:300]}";
    }
    run.execution_note = report_.line()[:2000];
    return report_;
}

"""The client order ID for a run's order: the portfolio's `tag`, run date, ticker, and purpose, so
a second firing finds the first order instead of placing another (TDD §8, idempotency)."""
def order_id_for(run_day: str, ticker: str, purpose: OrderPurpose, tag: str = "") -> str {
    found = f"{run_day}-{ticker.replace('/', '')}-{purpose.value}";
    return f"{tag}-{found}" if tag else found;
}

def limit_price(side: OrderSide, price: float) -> float {
    return round(price * (1.0 + LIMIT_OFFSET) if side == OrderSide.BUY else price * (1.0 - LIMIT_OFFSET), 2 if price >= 1.0 else 6);
}

"""A stop price rounded the way it is shown: to the cent at $1 and above, and finer below, where a
coin can trade for a fraction of a cent."""
def stop_round(price: float) -> float {
    return round(price, 2) if price >= 1.0 else round(price, 6);
}

"""The time in force for a run's order on `ticker`: Alpaca takes no DAY order for a coin."""
def entry_tif(ticker: str) -> str {
    return "gtc" if is_crypto(ticker) else "day";
}

"""Submit the order `rc` approved, as a marketable DAY limit at its checked price ±0.3%. A
position's working stop is canceled first: a buy beside it is a wash trade, and a sell needs
the shares it reserves. Refuses anything `rc` did not approve. `tick` is a coin's price increment.
Returns a line for the log."""
def submit(portfolio: Portfolio, rc: RiskCheck, broker: Broker, now: datetime, run_day: str, position: Position | None = None, tick: float = 0.0) -> str {
    if rc.side is None or rc.purpose is None or rc.approved_qty <= 0 or rc.price <= 0.0 {
        raise ValueError(f"{rc.ticker}: refusing an order the risk gate did not approve");
    }
    qty = rc.approved_qty;
    for stop in [o for o in broker.orders("open", [rc.ticker]) if o.side == "sell" and o.order_type in ("stop", "stop_limit")] {
        closed = broker.cancel_and_wait(stop.id);
        if closed.filled_qty > 0 {
            # The stop fired first: the position the order was sized for is gone or smaller.
            return _refused(portfolio, rc, now, run_day, qty, f"its stop filled ({closed.filled_qty:g}) before the order");
        }
    }
    if position is not None and position.stop_order_id {
        position.stop_order_id = "";
    }
    if rc.side == OrderSide.SELL {
        held = broker.positions().get(rc.ticker);
        qty = min(qty, held.qty_available if held is not None else 0);
        if qty <= 0 {
            return _refused(portfolio, rc, now, run_day, rc.approved_qty, "no shares available to sell");
        }
    }
    request = OrderRequest(
        symbol=rc.ticker,
        side=rc.side.value,
        qty=qty,
        order_type="limit",
        time_in_force=entry_tif(rc.ticker),
        client_order_id=order_id_for(run_day, rc.ticker, rc.purpose, portfolio.order_tag),
        limit_price=limit_price(rc.side, rc.price),
        price_increment=tick
    );
    order = Order(
        client_order_id=request.client_order_id,
        purpose=rc.purpose,
        side=rc.side,
        qty=qty,
        order_type="limit",
        time_in_force=request.time_in_force,
        submitted_at=now.isoformat(),
        limit_price=request.limit_price or 0.0,
        ticker=rc.ticker,
        asset_class=asset_class_of(rc.ticker)
    );
    try {
        placed = broker.submit(request);
        _update(order, placed, now);
    } except BrokerError as e {
        order.status = "rejected";
        order.reject_reason = e.detail[:300] or str(e)[:300];
    }
    public(rc +>:Placed():+> order);
    portfolio +>:Sent():+> order;
    return f"{rc.ticker} {rc.side.value} {qty:g} @ {_money(order.limit_price)}: {order.status}{' (' + order.reject_reason + ')' if order.reject_reason else ''}";
}

def _refused(portfolio: Portfolio, rc: RiskCheck, now: datetime, run_day: str, qty: float, reason: str) -> str {
    order = Order(
        client_order_id=order_id_for(run_day, rc.ticker, rc.purpose or OrderPurpose.ENTRY, portfolio.order_tag),
        purpose=rc.purpose or OrderPurpose.ENTRY,
        side=rc.side or OrderSide.BUY,
        qty=qty,
        order_type="limit",
        time_in_force=entry_tif(rc.ticker),
        submitted_at=now.isoformat(),
        status="rejected",
        reject_reason=f"not sent: {reason}",
        ticker=rc.ticker,
        asset_class=asset_class_of(rc.ticker)
    );
    public(rc +>:Placed():+> order);
    portfolio +>:Sent():+> order;
    return f"{rc.ticker}: not sent, {reason}";
}

def _update(order: Order, seen: BrokerOrder, now: datetime) {
    order.alpaca_order_id = seen.id;
    order.status = seen.status;
    order.updated_at = now.isoformat();
}

"""Refresh every working order from Alpaca, record each new fill as a Fill, and move the
positions with it. Returns a line per change."""
def sync_orders(portfolio: Portfolio, broker: Broker, now: datetime) -> list[str] {
    changes: list[str] = [];
    for order in working_orders(portfolio) {
        try {
            seen = broker.order(order.alpaca_order_id);
        } except BrokerError as e {
            changes.append(f"{order.client_order_id}: could not refresh ({e.status})");
            continue;
        }
        added = seen.filled_qty - order.filled_qty;
        if added > 0 and order.asset_class == CRYPTO {
            added = round(added, 12);
        }
        if added > 0 and seen.filled_avg_price is not None {
            # Alpaca reports the cumulative fill; the new shares' price follows from the averages.
            price = (seen.filled_avg_price * seen.filled_qty - order.filled_avg_price * order.filled_qty) / added;
            filled_at = seen.filled_at or now.isoformat();
            public(order +>:FilledBy():+> Fill(qty=added, price=price, filled_at=filled_at));
            order.filled_qty = seen.filled_qty;
            order.filled_avg_price = seen.filled_avg_price;
            changes.append(_apply_fill(portfolio, order, added, price, now, filled_at));
        }
        if seen.status != order.status {
            changes.append(f"{order.client_order_id}: {order.status} -> {seen.status}");
        }
        _update(order, seen, now);
    }
    return changes;
}

"""Move the portfolio's position in `order`'s stock by a fill of `qty` at `price`. A new position
dates from the broker's `filled_at`, not from this sync, so a sync the runtime replays after a
database conflict names the same stop (`stop_id_for`) and finds the stop it placed."""
def _apply_fill(portfolio: Portfolio, order: Order, qty: float, price: float, now: datetime, filled_at: str) -> str {
    position = open_positions(portfolio, True).get(order.ticker);
    kind = order.asset_class or asset_class_of(order.ticker);
    if order.side == OrderSide.BUY {
        found = [rc for rc in [order <-:Placed:<-[?:RiskCheck]]];
        distance = found[0].stop_distance if found else 0.0;
        if position is None {
            decided = [d for rc in found for d in [rc <-:CheckedBy:<-[?:Decision]]];
            covered = [c for d in decided for c in [d <-:Decided:<-[?:Coverage]]];
            position = public(portfolio +>:Holds():+> Position(
                ticker=order.ticker,
                sector=covered[0].sector if covered else "",
                qty=qty,
                avg_entry_price=price,
                opened_at=filled_at,
                stop_price=stop_round(price - distance) if distance > 0 else 0.0,
                last_price=price,
                priced_at=now.isoformat(),
                asset_class=kind,
                multiplier=100.0 if kind == OPTIONS else 1.0
            ));
            if decided {
                position +>:OpenedBy():+> decided[0];
            }
            return f"{order.ticker}: opened {qty:g} @ {_money(price)}" + (f", stop {_money(position.stop_price)}" if position.stop_price > 0 else "");
        }
        position.avg_entry_price = (position.avg_entry_price * position.qty + price * qty) / (position.qty + qty);
        position.qty += qty;
        if kind == CRYPTO {
            position.qty = round(position.qty, 12);
        }
        if distance > 0 {
            # An add never loosens the stop.
            position.stop_price = max(position.stop_price, stop_round(price - distance));
        }
        return f"{order.ticker}: added {qty:g} @ {_money(price)}, now {position.qty:g}" + (f", stop {_money(position.stop_price)}" if position.stop_price > 0 else "");
    }
    if position is None {
        return f"{order.ticker}: sold {qty:g} @ {_money(price)} with no open position on record";
    }
    before = position.qty;
    position.qty -= qty;
    if kind == CRYPTO {
        position.qty = round(position.qty, 12);
        if order.purpose in (OrderPurpose.EXIT, OrderPurpose.STOP) and position.qty <= before * DUST_FRACTION {
            position.qty = 0;
        }
    }
    if position.qty <= 0 {
        position.qty = 0;
        position.closed_at = now.isoformat();
        position.exit_price = price;
        position.stop_order_id = "";
        return f"{order.ticker}: closed @ {_money(price)} ({order.purpose.value})";
    }
    return f"{order.ticker}: sold {qty:g} @ {_money(price)} ({order.purpose.value}), {position.qty:g} left";
}

"""A price in dollars, with the precision a sub-dollar coin needs."""
def _money(value: float) -> str {
    return f"{value:.2f}" if abs(value) >= 1.0 else f"{value:.4g}";
}

"""The client order ID for a position's `n`th stop: the portfolio's `tag`, the stock, when the
position opened, and the count, so a re-placed stop never reuses an ID."""
def stop_id_for(position: Position, n: int, tag: str = "") -> str {
    opened = "".join(ch for ch in position.opened_at[:19] if ch.isdigit());
    found = f"{position.ticker.replace('/', '')}-{opened}-stop{n}";
    return f"{tag}-{found}" if tag else found;
}

"""Give every open position exactly one working GTC stop sell for all its shares at its stop
price. A stock with a working buy or non-stop sell waits for that order to finish. When the
price is already at or below the stop, the position is sold at once with a marketable
limit, since Alpaca would refuse a sell stop above the market. A coin's stop is a stop-limit, and
`coins_only` leaves stocks alone on a day the stock market is closed. Returns a line per change."""
def keep_stops(portfolio: Portfolio, broker: Broker, now: datetime, prices: dict[str, float] | None = None, coins_only: bool = False) -> list[str] {
    changes: list[str] = [];
    if orders_disabled() {
        return changes;
    }
    positions = {t: p for (t, p) in open_positions(portfolio).items() if not coins_only or is_crypto(t)};
    if not positions {
        return changes;
    }
    held = broker.positions();
    working = broker.orders("open", sorted(positions));
    ticks = coin_ticks([t for t in positions if is_crypto(t)]);
    for (ticker, position) in sorted(positions.items()) {
        at_broker = held.get(ticker);
        if at_broker is None or at_broker.qty <= 0 {
            # Reconciliation closes it; nothing here to protect.
            continue;
        }
        mine = [o for o in working if o.symbol == ticker];
        if any(o.side == "buy" or o.order_type not in ("stop", "stop_limit") for o in mine) {
            continue;
        }
        if position.stop_price <= 0.0 {
            changes.append(f"{ticker}: no stop price on record; reconciliation must set one");
            continue;
        }
        stops = [o for o in mine if o.side == "sell"];
        coin = is_crypto(ticker);
        if len(stops) == 1 and _same_qty(stops[0].qty, at_broker.qty, coin) and stops[0].stop_price is not None and abs(stops[0].stop_price - position.stop_price) < (0.005 if position.stop_price >= 1.0 else position.stop_price * 0.001) {
            position.stop_order_id = stops[0].id;
            continue;
        }
        fired = False;
        for s in stops {
            closed = broker.cancel_and_wait(s.id);
            fired = fired or closed.filled_qty > 0;
        }
        if fired {
            changes.append(f"{ticker}: a stop filled while being replaced; next sync records it");
            continue;
        }
        last = (prices or {}).get(ticker) or at_broker.current_price;
        position.stops_placed += 1;
        stop_out = last > 0.0 and last <= position.stop_price;
        request = OrderRequest(
            symbol=ticker,
            side="sell",
            qty=at_broker.qty,
            order_type="limit" if stop_out else "stop_limit" if coin else "stop",
            time_in_force="gtc" if coin else "day" if stop_out else "gtc",
            client_order_id=stop_id_for(position, position.stops_placed, portfolio.order_tag),
            limit_price=limit_price(OrderSide.SELL, last) if stop_out else stop_round(position.stop_price * (1.0 - CRYPTO_STOP_SLIPPAGE)) if coin else None,
            stop_price=None if stop_out else position.stop_price,
            price_increment=ticks.get(ticker, 0.0)
        );
        order = Order(
            client_order_id=request.client_order_id,
            purpose=OrderPurpose.STOP,
            side=OrderSide.SELL,
            qty=at_broker.qty,
            order_type=request.order_type,
            time_in_force=request.time_in_force,
            submitted_at=now.isoformat(),
            limit_price=request.limit_price or 0.0,
            stop_price=position.stop_price,
            ticker=ticker,
            asset_class=asset_class_of(ticker)
        );
        try {
            placed = broker.submit(request);
            _update(order, placed, now);
            position.stop_order_id = placed.id;
        } except BrokerError as e {
            order.status = "rejected";
            order.reject_reason = e.detail[:300] or str(e)[:300];
        }
        public(position +>:StoppedBy():+> order);
        portfolio +>:Sent():+> order;
        what = f"sold at {_money(order.limit_price)}, the price {_money(last)} is at or below the stop {_money(position.stop_price)}" if stop_out else f"stop for {at_broker.qty:g} at {_money(position.stop_price)}";
        changes.append(f"{ticker}: {what}: {order.status}{' (' + order.reject_reason + ')' if order.reject_reason else ''}");
    }
    return changes;
}

"""Each coin's price increment, from Alpaca's asset list (cached for a day), so a stop's prices are
ones Alpaca takes. A failed read leaves the cent tick, which a coin above $1 accepts."""
def coin_ticks(coins: list[str]) -> dict[str, float] {
    if not coins {
        return {};
    }
    try {
        listed = crypto_assets(run_budget());
    } except Exception {
        return {};
    }
    return {c: listed[c].price_increment for c in coins if c in listed};
}

"""True when a stop for `ordered` covers a position of `held`: exactly for shares, and within a
millionth for a coin's fraction."""
def _same_qty(ordered: float, held: float, coin: bool) -> bool {
    return abs(ordered - held) <= max(abs(held), 1.0) * 1e-6 if coin else ordered == held;
}

"""Cancel `run`'s DAY orders that are still working (TDD §8: unfilled orders are canceled at
3:50 p.m. and re-evaluated the next morning), then record what filled and re-place stops; only
coins' stops with `coins_only`, on a day the stock market is closed. Runs once per run."""
def close_day_orders(portfolio: Portfolio, run: Run, broker: Broker, now: datetime, coins_only: bool = False) -> list[str] {
    if run.day_orders_closed_at {
        return [f"day orders already closed at {run.day_orders_closed_at}"];
    }
    run.day_orders_closed_at = now.isoformat();
    changes = sync_orders(portfolio, broker, now);
    for order in working_orders(portfolio) {
        # A coin's entries and exits are GTC, since Alpaca takes no DAY order for one, but the run
        # closes them at the same time as a stock's.
        if order.time_in_force == "day" or (order.asset_class == CRYPTO and order.purpose != OrderPurpose.STOP) {
            closed = broker.cancel_and_wait(order.alpaca_order_id);
            changes.append(f"{order.client_order_id}: canceled at the close window ({closed.filled_qty:g} of {order.qty:g} filled)");
        }
    }
    changes.extend(sync_orders(portfolio, broker, now));
    changes.extend(keep_stops(portfolio, broker, now, coins_only=coins_only));
    return changes;
}

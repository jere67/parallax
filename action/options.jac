"""Long calls and puts on the stock panel's views (TDD §8, execution; models/assets.jac).

An agent that trades options buys them on the views its stock panel already formed, so no model
reads or decides anything here:

- a call on a BUY or ADD decision;
- a put on a stock it does not hold whose consensus is a confident sell: a score at or below
  `put_score` with the whole confidence interval below zero.

Only long options: the most a contract can lose is its premium. Each view buys the contract
`target_days` out (from `min_days` to `max_days`) nearest the money on the side the view expects
the stock to move, and only when its spread is at most `max_spread` of its mid. It pays at most
`position_premium` of equity, all options together at most `total_premium`, and at most
`new_per_day` new contracts a day, highest conviction first. No option is bought while the
drawdown breaker is on.

A contract is sold when it has `exit_days` or fewer days left, when its premium has fallen to
`loss_exit` of what was paid or risen to `gain_exit` of it, when the panel's latest decision on its
stock turns the other way, or when its opening decision's time stop arrives.

Every entry and exit is recorded as a RiskCheck with the rules it passed, and its Order hangs off
the check, so reconciliation traces each one (action/reconcile.jac). Entries hang off the decision
they act on, like a stock order's; exits hang off the portfolio. Orders are DAY limits, since
Alpaca takes no other kind for options outside market hours: an entry at the mid plus a quarter of
the spread, and an exit at the bid.
"""
import math;
import from datetime { date, datetime }
import from action.broker { Broker, BrokerError, OrderRequest }
import from action.executor { FINISHED_STATUSES, MarketView, breaker_peak_of, decisions_of, open_positions, orders_disabled }
import from action.gate { GateConfig }
import from models.assets { OPTIONS }
import from models.graph {
    CheckedBy,
    Concluded,
    ConsensusResult,
    Coverage,
    Covers,
    Decided,
    Decision,
    OpenedBy,
    Order,
    OrderPurpose,
    OrderSide,
    Placed,
    Portfolio,
    PortfolioMode,
    Position,
    Ran,
    RiskCheck,
    RiskOutcome,
    RuleResult,
    Run,
    RunStatus,
    Sent,
    TradeAction
}
import from research.collector { run_budget }
import from research.options {
    CALL,
    CONTRACT_SIZE,
    PUT,
    ContractQuery,
    OptionContract,
    OptionQuote,
    choose_contract,
    describe_option,
    expiry_window,
    option_contracts,
    option_quotes,
    parse_occ
}
import from run.public { public }

# Bump with any change to the rules or their defaults, so each check records what judged it.
glob OPTIONS_VERSION: str = "2026-11-14.1";

obj OptionsConfig {
    has min_days: int = 21,
        max_days: int = 60,
        target_days: int = 35,
        position_premium: float = 0.01,
        total_premium: float = 0.05,
        new_per_day: int = 2,
        max_spread: float = 0.25,
        put_score: float = -0.25,
        strike_band: float = 0.15,
        exit_days: int = 7,
        loss_exit: float = 0.5,
        gain_exit: float = 2.0;
}

"""The rules options follow, and what they read from outside: contracts and quotes. Tests pass
fakes; the defaults call Alpaca."""
obj OptionsDeps {
    has config: OptionsConfig = OptionsConfig(),
        contracts: Callable[[ContractQuery], list[OptionContract]] | None = None,
        quotes: Callable[[list[str]], dict[str, OptionQuote]] | None = None;

    def list_contracts(query: ContractQuery) -> list[OptionContract] {
        return self.contracts(query) if self.contracts is not None else option_contracts(query, run_budget());
    }

    def read_quotes(symbols: list[str]) -> dict[str, OptionQuote] {
        if self.quotes is not None {
            return self.quotes(symbols);
        }
        (found, _gaps) = option_quotes(symbols, run_budget());
        return found;
    }
}

"""One view an option could be bought on: the stock, call or put, and how sure the panel is."""
obj OptionView {
    has ticker: str,
        kind: str,
        conviction: float,
        decision: Decision,
        price: float;
}

"""The price tick Alpaca takes for an option at `price`: a nickel from $3, a penny below."""
def option_tick(price: float) -> float {
    return 0.05 if price >= 3.0 else 0.01;
}

"""`price` rounded to the option tick, down for a sell and up for a buy."""
def to_tick(price: float, up: bool) -> float {
    tick = option_tick(price);
    steps = math.ceil(price / tick - 1e-9) if up else math.floor(price / tick + 1e-9);
    return round(max(tick, steps * tick), 2);
}

"""The calls and puts `run`'s decisions point to, highest conviction first. A stock the portfolio
holds is never shorted through a put; it is sold."""
def option_views(run: Run, held: set[str], view: MarketView, config: OptionsConfig) -> list[OptionView] {
    found: list[OptionView] = [];
    for (ticker, (cov, d)) in decisions_of(run).items() {
        price = view.price(ticker) or cov.last_close;
        if price <= 0.0 or "/" in ticker {
            continue;
        }
        if d.action in (TradeAction.BUY, TradeAction.ADD) and d.conviction > 0.0 {
            found.append(OptionView(ticker=ticker, kind=CALL, conviction=d.conviction, decision=d, price=price));
            continue;
        }
        if ticker in held or d.forced_hold_reason {
            continue;
        }
        for c in [cov ->:Concluded:->[?:ConsensusResult]] {
            if c.score <= config.put_score and c.ci_high < 0.0 {
                found.append(OptionView(ticker=ticker, kind=PUT, conviction=min(1.0, abs(c.score)), decision=d, price=price));
            }
        }
    }
    return sorted(found, key=lambda (v: OptionView) { (-v.conviction, v.ticker); });
}

"""Buy the options `run`'s decisions point to, once per run. Returns a line per view."""
def open_options(
    portfolio: Portfolio,
    run: Run,
    broker: Broker,
    now: datetime,
    view: MarketView,
    gate: GateConfig = GateConfig(),
    deps: OptionsDeps = OptionsDeps()
) -> list[str] {
    config = deps.config;
    if run.options_at or OPTIONS not in run.asset_classes or portfolio.mode != PortfolioMode.AUTO or run.status in (RunStatus.RUNNING, RunStatus.SKIPPED) {
        return [];
    }
    run.options_at = now.isoformat();
    account = broker.account();
    positions = broker.positions();
    held_options = {t: p for (t, p) in positions.items() if p.asset_class == OPTIONS and p.qty > 0};
    held_stocks = {t for (t, p) in positions.items() if p.asset_class != OPTIONS and p.qty > 0};
    underlyings = {parts.underlying for parts in [parse_occ(t) for t in held_options] if parts is not None};
    spent: float = sum(abs(p.market_value) for p in held_options.values());
    peak = max(breaker_peak_of(portfolio, gate), account.equity);
    drawn_down = peak > 0 and account.equity <= peak * (1.0 - gate.drawdown_halt);
    lines: list[str] = [];
    opened = 0;
    today = now.date().isoformat();
    for v in option_views(run, held_stocks, view, config) {
        if v.ticker in underlyings {
            continue;
        }
        rules: list[RuleResult] = [];
        def refuse(rule: str, detail: str) -> str {
            rules.append(RuleResult(rule=rule, passed=False, detail=detail));
            _record_check(v.decision, v.ticker, 0, 0.0, rules, now, RiskOutcome.REJECTED);
            return f"{v.ticker} {v.kind}: {detail}";
        }
        if drawn_down {
            lines.append(refuse("drawdown breaker", f"equity is {1 - account.equity / peak:.1%} below its peak; no new options"));
            continue;
        }
        if opened >= config.new_per_day {
            lines.append(refuse("new options per day", f"{config.new_per_day} new options a day, kept for higher conviction"));
            continue;
        }
        (start, end) = expiry_window(today, config.min_days, config.max_days);
        band = (v.price * (1.0 - config.strike_band), v.price * (1.0 + config.strike_band));
        try {
            listed = deps.list_contracts(ContractQuery(underlying=v.ticker, kind=v.kind, expiry_from=start, expiry_to=end, strike_low=band[0], strike_high=band[1]));
        } except Exception as e {
            lines.append(refuse("contract", f"no contract list ({type(e).__name__})"));
            continue;
        }
        chosen = choose_contract(listed, v.price, v.kind, today, config.min_days, config.max_days, config.target_days);
        if chosen is None {
            lines.append(refuse("contract", f"no tradable {v.kind} {config.min_days} to {config.max_days} days out near ${v.price:,.2f}"));
            continue;
        }
        rules.append(RuleResult(rule="contract", passed=True, detail=f"{describe_option(chosen.symbol)}, strike nearest the money on the side of the view"));
        try {
            quote = deps.read_quotes([chosen.symbol]).get(chosen.symbol);
        } except Exception {
            quote = None;
        }
        if quote is None or quote.mid() <= 0.0 {
            lines.append(refuse("quote", f"no two-sided quote for {chosen.symbol}"));
            continue;
        }
        if quote.spread() > config.max_spread {
            lines.append(refuse("spread", f"the spread is {quote.spread():.0%} of the mid, above {config.max_spread:.0%}"));
            continue;
        }
        rules.append(RuleResult(rule="spread", passed=True, detail=f"bid {quote.bid:.2f}, ask {quote.ask:.2f}"));
        limit = min(to_tick(quote.mid() + 0.25 * (quote.ask - quote.bid), True), to_tick(quote.ask, True));
        cost = limit * CONTRACT_SIZE;
        room = min(config.position_premium * account.equity, config.total_premium * account.equity - spent);
        qty = int(math.floor(room / cost)) if cost > 0 else 0;
        if qty < 1 {
            lines.append(refuse("premium budget", f"one contract costs ${cost:,.0f}; the room is ${max(0.0, room):,.0f} ({config.position_premium:.0%} of equity each, {config.total_premium:.0%} in all)"));
            continue;
        }
        rules.append(RuleResult(rule="premium budget", passed=True, detail=f"{qty} contract{'s' if qty != 1 else ''} at ${limit:.2f} costs ${qty * cost:,.0f}", qty_before=qty, qty_after=qty));
        rc = _record_check(v.decision, chosen.symbol, qty, limit, rules, now, RiskOutcome.APPROVED);
        lines.append(_send(portfolio, rc, broker, now, OrderRequest(
            symbol=chosen.symbol,
            side="buy",
            qty=qty,
            order_type="limit",
            time_in_force="day",
            client_order_id=_order_id(portfolio, run.run_date, chosen.symbol, "entry"),
            limit_price=limit,
            position_intent="buy_to_open"
        ), OrderPurpose.ENTRY));
        spent += qty * cost;
        opened += 1;
        underlyings.add(v.ticker);
    }
    return lines;
}

"""Why the open option `p` should be sold on `today`, or "" to keep it. `quote` is its latest
quote and `latest` the newest decision on its stock."""
def exit_reason(p: Position, today: str, quote: OptionQuote | None, latest: Decision | None, config: OptionsConfig = OptionsConfig()) -> str {
    parts = parse_occ(p.ticker);
    if parts is None {
        return "";
    }
    left = (date.fromisoformat(parts.expiry) - date.fromisoformat(today)).days;
    if left <= config.exit_days {
        return f"{left} days to expiry";
    }
    mid = quote.mid() if quote is not None else 0.0;
    if mid > 0.0 and p.avg_entry_price > 0.0 {
        if mid <= p.avg_entry_price * config.loss_exit {
            return f"the premium fell to {mid / p.avg_entry_price:.0%} of the {p.avg_entry_price:.2f} paid";
        }
        if mid >= p.avg_entry_price * config.gain_exit {
            return f"the premium rose to {mid / p.avg_entry_price:.0%} of the {p.avg_entry_price:.2f} paid";
        }
    }
    if latest is not None {
        against = (TradeAction.SELL, TradeAction.TRIM) if parts.kind == CALL else (TradeAction.BUY, TradeAction.ADD);
        if latest.action in against {
            return f"the panel now says {latest.action.value} on {parts.underlying}";
        }
    }
    for d in [p ->:OpenedBy:->[?:Decision]] {
        if d.time_stop and d.time_stop <= today {
            return f"its time stop {d.time_stop} arrived";
        }
    }
    return "";
}

"""Sell every open option an exit rule calls for. Returns a line per sale."""
def manage_options(portfolio: Portfolio, broker: Broker, now: datetime, deps: OptionsDeps = OptionsDeps()) -> list[str] {
    if orders_disabled() or portfolio.mode != PortfolioMode.AUTO {
        return [];
    }
    held = [p for p in open_positions(portfolio, True).values() if p.asset_class == OPTIONS];
    if not held {
        return [];
    }
    working = {o.ticker for o in [portfolio ->:Sent:->[?:Order]] if o.status not in FINISHED_STATUSES and o.side == OrderSide.SELL};
    try {
        quotes = deps.read_quotes([p.ticker for p in held]);
    } except Exception {
        quotes = {};
    }
    latest = latest_decisions(portfolio);
    at_broker = broker.positions();
    today = now.date().isoformat();
    lines: list[str] = [];
    for p in held {
        parts = parse_occ(p.ticker);
        found = at_broker.get(p.ticker);
        if parts is None or p.ticker in working or found is None or found.qty <= 0 {
            continue;
        }
        quote = quotes.get(p.ticker);
        reason = exit_reason(p, today, quote, latest.get(parts.underlying), deps.config);
        if not reason {
            continue;
        }
        limit = to_tick(quote.bid, False) if quote is not None and quote.bid > 0.0 else 0.01;
        qty = int(found.qty);
        rc = public(portfolio ++> RiskCheck(
            outcome=RiskOutcome.APPROVED,
            approved_qty=qty,
            checked_at=now.isoformat(),
            rules=[RuleResult(rule="option exit", passed=True, detail=reason, qty_before=qty, qty_after=qty)],
            ticker=p.ticker,
            side=OrderSide.SELL,
            purpose=OrderPurpose.EXIT,
            requested_qty=qty,
            price=limit,
            gate_version=OPTIONS_VERSION,
            asset_class=OPTIONS
        ));
        p.stops_placed += 1;
        lines.append(_send(portfolio, rc, broker, now, OrderRequest(
            symbol=p.ticker,
            side="sell",
            qty=qty,
            order_type="limit",
            time_in_force="day",
            client_order_id=_order_id(portfolio, today, p.ticker, f"exit{p.stops_placed}"),
            limit_price=limit,
            position_intent="sell_to_close"
        ), OrderPurpose.EXIT) + f" ({reason})");
    }
    return lines;
}

"""The newest decision on each stock across the portfolio's runs."""
def latest_decisions(portfolio: Portfolio) -> dict[str, Decision] {
    found: dict[str, Decision] = {};
    for run in sorted([portfolio ->:Ran:->[?:Run]], key=lambda (r: Run) { r.run_date; }) {
        for (ticker, (_, d)) in decisions_of(run).items() {
            found[ticker] = d;
        }
    }
    return found;
}

def _record_check(decision: Decision, symbol: str, qty: int, price: float, rules: list[RuleResult], now: datetime, outcome: RiskOutcome) -> RiskCheck {
    rc = RiskCheck(
        outcome=outcome,
        approved_qty=qty,
        checked_at=now.isoformat(),
        rules=list(rules),
        ticker=symbol,
        side=OrderSide.BUY,
        purpose=OrderPurpose.ENTRY,
        requested_qty=qty,
        price=price,
        gate_version=OPTIONS_VERSION,
        asset_class=OPTIONS
    );
    public(decision +>:CheckedBy():+> rc);
    return rc;
}

def _order_id(portfolio: Portfolio, day: str, symbol: str, what: str) -> str {
    found = f"{day}-{symbol}-{what}";
    return f"{portfolio.order_tag}-{found}" if portfolio.order_tag else found;
}

"""Submit `request` for the check `rc` approved and record its Order. Returns a line for the log."""
def _send(portfolio: Portfolio, rc: RiskCheck, broker: Broker, now: datetime, request: OrderRequest, purpose: OrderPurpose) -> str {
    order = Order(
        client_order_id=request.client_order_id,
        purpose=purpose,
        side=OrderSide.BUY if request.side == "buy" else OrderSide.SELL,
        qty=request.qty,
        order_type="limit",
        time_in_force="day",
        submitted_at=now.isoformat(),
        limit_price=request.limit_price or 0.0,
        ticker=request.symbol,
        asset_class=OPTIONS
    );
    if orders_disabled() {
        order.status = "rejected";
        order.reject_reason = "not sent: orders are disabled";
    } else {
        try {
            placed = broker.submit(request);
            order.alpaca_order_id = placed.id;
            order.status = placed.status;
            order.updated_at = now.isoformat();
        } except BrokerError as e {
            order.status = "rejected";
            order.reject_reason = e.detail[:300] or str(e)[:300];
        }
    }
    public(rc +>:Placed():+> order);
    portfolio +>:Sent():+> order;
    return f"{describe_option(request.symbol)} {request.side} {request.qty:g} @ {order.limit_price:.2f}: {order.status}{' (' + order.reject_reason + ')' if order.reject_reason else ''}";
}

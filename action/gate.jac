"""The risk gate (TDD §8, risk gate; FR-09): deterministic rules every proposed order passes
before it may reach the broker.

The gate takes the sized orders, a snapshot of the portfolio, each ticker's instrument facts,
and the market regime, and approves, resizes, or rejects each order, recording every rule it
evaluated. No model reads or changes anything here.

Exits always go first: a sell is refused only when the broker cannot trade the stock, and it
is never cut short, so risk can always come off. Buys then pass, in order:

1. instrument checks: active, tradable, priced above the floor, and traded recently (a stock
   with no recent trade may be halted);
2. the earnings blackout;
3. the drawdown breaker;
4. the protective stop: a buy needs an ATR, so its stop at entry minus 2 ATR can be placed;
5. the per-position cap;
6. liquidity: no more than 1% of the 20-day average daily volume;
7. new positions per day, keeping the highest conviction;
8. the sector cap, filled in conviction order, so the lowest-conviction ("newest") order is
   resized or rejected;
9. gross exposure, capped lower when the regime filter is on, scaling every buy down together;
10. daily turnover, which exits use first, scaling every buy down together.

Every scaling floors to whole shares, so no cap is crossed by rounding.
"""
import math;
import from models.graph { OrderPurpose, OrderSide, RiskOutcome, RuleResult, TradeAction }
import from models.research { RegimeInputs }

# Bump with any change to the rules or their defaults, so each check records what judged it.
glob GATE_VERSION: str = "2026-10-20.1";

glob UNKNOWN_SECTOR: str = "unknown sector";

obj GateConfig {
    has max_position_weight: float = 0.10,
        sector_cap: float = 0.30,
        gross_limit: float = 0.90,
        new_positions_per_day: int = 3,
        turnover_limit: float = 0.25,
        drawdown_halt: float = 0.10,
        regime_gross_limit: float = 0.50,
        regime_vol: float = 0.30,
        earnings_blackout_sessions: int = 2,
        adv_fraction: float = 0.01,
        min_price: float = 5.0,
        stop_atr_multiple: float = 2.0,
        max_trade_age_minutes: float = 15.0;
}

"""What the gate needs to know about one stock at the moment of the check. `price` is the
latest trade; `trade_age_minutes` is how old that trade is (None when unknown); `volume_20`
is the 20-day average daily volume in shares; `sessions_to_earnings` counts trading sessions
from today to the next earnings release (0 when it reports today, None when none is due)."""
obj Instrument {
    has ticker: str,
        price: float;
    has sector: str = "",
        tradable: bool = True,
        active: bool = True,
        trade_age_minutes: float | None = None,
        atr_14: float | None = None,
        volume_20: float | None = None,
        sessions_to_earnings: int | None = None;
}

obj BookPosition {
    has ticker: str,
        qty: int,
        price: float;
    has sector: str = "";
}

"""The portfolio at the moment of the check. `new_positions_today` and `turnover_today`
(dollars traded so far today) count what earlier orders today already used."""
obj Book {
    has equity: float,
        peak_equity: float;
    has positions: dict[str, BookPosition] = {},
        new_positions_today: int = 0,
        turnover_today: float = 0.0;

    def held(ticker: str) -> int {
        p = self.positions.get(ticker);
        return p.qty if p is not None else 0;
    }
}

"""One sized order before the gate: `qty` whole shares on `side`."""
obj Proposal {
    has ticker: str,
        action: TradeAction,
        side: OrderSide,
        qty: int,
        conviction: float;

    def purpose(held: int) -> OrderPurpose {
        if self.side == OrderSide.BUY {
            return OrderPurpose.ADD if held > 0 else OrderPurpose.ENTRY;
        }
        return OrderPurpose.EXIT if self.qty >= held else OrderPurpose.TRIM;
    }
}

"""The gate's ruling on one proposal. `stop_distance` is the dollar distance below the fill
price for the protective stop of a buy (0 for a sell)."""
obj GateResult {
    has ticker: str,
        action: TradeAction,
        side: OrderSide,
        purpose: OrderPurpose,
        requested_qty: int,
        approved_qty: int,
        conviction: float;
    has rules: list[RuleResult] = [],
        stop_distance: float = 0.0,
        price: float = 0.0;

    def outcome -> RiskOutcome {
        if self.approved_qty <= 0 {
            return RiskOutcome.REJECTED;
        }
        return RiskOutcome.RESIZED if self.approved_qty < self.requested_qty else RiskOutcome.APPROVED;
    }

    def rejected_by -> str {
        failed = [r.rule for r in self.rules if not r.passed];
        return failed[-1] if failed else "";
    }

    """Record a rule. A rule that cut the quantity, or failed, is recorded as not passed."""
    def apply(rule: str, qty: int, detail: str = "") {
        before = self.approved_qty;
        after = max(0, min(before, qty));
        self.rules.append(RuleResult(rule=rule, passed=after == before, detail=detail, qty_before=before, qty_after=after));
        self.approved_qty = after;
    }

    def alive -> bool {
        return self.approved_qty > 0;
    }
}

"""Whether the regime filter caps gross exposure: SPY below its 200-day average and its 20-day
realized volatility above the limit. A missing figure counts as on, so the gate fails safe."""
def regime_on(regime: RegimeInputs | None, config: GateConfig) -> tuple[bool, str] {
    if regime is None or regime.spy_vol_20 is None or regime.spy_above_200d() is None {
        return (True, "regime figures are missing, so the lower cap applies");
    }
    above = regime.spy_above_200d();
    vol = regime.spy_vol_20 or 0.0;
    if not above and vol > config.regime_vol {
        return (True, f"SPY is below its 200-day average and its 20-day volatility is {vol:.0%}");
    }
    return (False, f"SPY {'above' if above else 'below'} its 200-day average, 20-day volatility {vol:.0%}");
}

"""Run every proposal through the gate. Returns one result per proposal, in proposal order."""
def check_orders(
    proposals: list[Proposal],
    book: Book,
    instruments: dict[str, Instrument],
    regime: RegimeInputs | None,
    config: GateConfig = GateConfig()
) -> list[GateResult] {
    if not math.isfinite(book.equity) or book.equity <= 0.0 {
        raise ValueError("the gate needs positive equity");
    }
    if len({p.ticker for p in proposals}) != len(proposals) {
        raise ValueError("the gate takes one proposal per ticker");
    }
    equity = book.equity;
    results: list[GateResult] = [];
    for p in proposals {
        found = instruments.get(p.ticker);
        held = book.held(p.ticker);
        results.append(GateResult(
            ticker=p.ticker,
            action=p.action,
            side=p.side,
            purpose=p.purpose(held),
            requested_qty=max(0, p.qty),
            approved_qty=max(0, p.qty),
            conviction=p.conviction,
            price=found.price if found is not None else 0.0
        ));
    }
    sells = [r for r in results if r.side == OrderSide.SELL];
    buys = [r for r in results if r.side == OrderSide.BUY];

    # Exits: only an untradable stock or a quantity above the shares held stops a sell.
    for r in sells {
        found = instruments.get(r.ticker);
        if found is None or not found.tradable or not found.active {
            r.apply("instrument checks", 0, "the broker cannot trade this stock today; the exit waits for the next run");
            continue;
        }
        r.apply("shares held", book.held(r.ticker), f"{book.held(r.ticker)} shares held");
    }
    sold = {r.ticker: r.approved_qty for r in sells};
    after_sells = {t: p.qty - sold.get(t, 0) for (t, p) in book.positions.items()};

    def price_of(ticker: str) -> float {
        found = instruments.get(ticker);
        if found is not None and found.price > 0 {
            return found.price;
        }
        held_at = book.positions.get(ticker);
        return held_at.price if held_at is not None else 0.0;
    }
    def sector_of(ticker: str) -> str {
        found = instruments.get(ticker);
        if found is not None and found.sector {
            return found.sector;
        }
        held_at = book.positions.get(ticker);
        return held_at.sector if held_at is not None and held_at.sector else UNKNOWN_SECTOR;
    }

    # 1 to 4: per-order checks that reject.
    drawn_down = book.peak_equity > 0 and equity <= book.peak_equity * (1.0 - config.drawdown_halt);
    for r in buys {
        found = instruments.get(r.ticker);
        if found is None {
            r.apply("instrument checks", 0, "no instrument data");
            continue;
        }
        if not found.active or not found.tradable {
            r.apply("instrument checks", 0, "not active and tradable on Alpaca");
        } elif not math.isfinite(found.price) or found.price <= config.min_price {
            r.apply("instrument checks", 0, f"price {found.price:.2f} is not above ${config.min_price:.0f}");
        } elif found.trade_age_minutes is None or found.trade_age_minutes > config.max_trade_age_minutes {
            r.apply("instrument checks", 0, "no trade in the last 15 minutes, so it may be halted" if found.trade_age_minutes is not None else "no recent trade");
        } else {
            r.apply("instrument checks", r.approved_qty, f"active, tradable, last trade {found.price:.2f}");
        }
        if not r.alive() {
            continue;
        }
        due = found.sessions_to_earnings;
        if due is not None and due <= config.earnings_blackout_sessions {
            when = "today" if due == 0 else f"in {due} trading session{'' if due == 1 else 's'}";
            r.apply("earnings blackout", 0, f"earnings {when}; logged as insight only");
            continue;
        }
        r.apply("earnings blackout", r.approved_qty, f"no earnings within {config.earnings_blackout_sessions} sessions");
        if drawn_down {
            r.apply("drawdown breaker", 0, f"equity {equity:,.0f} is {1 - equity / book.peak_equity:.1%} below the peak {book.peak_equity:,.0f}; new buys halt");
            continue;
        }
        r.apply("drawdown breaker", r.approved_qty, "");
        atr = found.atr_14;
        if atr is None or not math.isfinite(atr) or atr <= 0.0 or found.price - config.stop_atr_multiple * atr <= 0.0 {
            r.apply("protective stop", 0, "no usable ATR(14), so no protective stop can be set");
            continue;
        }
        r.stop_distance = config.stop_atr_multiple * atr;
        r.apply("protective stop", r.approved_qty, f"stop {r.stop_distance:.2f} below the fill (2 x ATR {atr:.2f})");
    }

    # 5 and 6: per-order caps that resize.
    for r in [b for b in buys if b.alive()] {
        found = instruments[r.ticker];
        room = int(math.floor(config.max_position_weight * equity / found.price)) - book.held(r.ticker);
        r.apply("per-position cap", room, f"at most {config.max_position_weight:.0%} of equity, {max(0, room)} more shares");
        if not r.alive() {
            continue;
        }
        adv = found.volume_20;
        if adv is None or not math.isfinite(adv) or adv <= 0.0 {
            r.apply("liquidity", 0, "no 20-day average volume");
        } else {
            r.apply("liquidity", int(math.floor(config.adv_fraction * adv)), f"at most 1% of {adv:,.0f} average daily shares");
        }
    }

    # 7: new positions per day, highest conviction first.
    ranked = sorted([b for b in buys if b.alive()], key=lambda (b: GateResult) { (-b.conviction, b.ticker); });
    slots = max(0, config.new_positions_per_day - book.new_positions_today);
    for r in ranked {
        if r.purpose != OrderPurpose.ENTRY {
            continue;
        }
        if slots > 0 {
            slots -= 1;
            r.apply("new positions per day", r.approved_qty, "");
        } else {
            r.apply("new positions per day", 0, f"{config.new_positions_per_day} new positions a day, kept for higher conviction");
        }
    }

    # 8: sector cap, in conviction order.
    sector_value: dict[str, float] = {};
    for (t, qty) in after_sells.items() {
        if qty > 0 {
            sector_value[sector_of(t)] = sector_value.get(sector_of(t), 0.0) + qty * price_of(t);
        }
    }
    for r in [b for b in ranked if b.alive()] {
        sector = sector_of(r.ticker);
        used = sector_value.get(sector, 0.0);
        room = int(math.floor(max(0.0, config.sector_cap * equity - used) / price_of(r.ticker)));
        r.apply("sector cap", room, f"{sector} holds {used / equity:.1%} of equity before this order");
        sector_value[sector] = used + r.approved_qty * price_of(r.ticker);
    }

    # 9: gross exposure, lower under the regime filter.
    (filtered, why) = regime_on(regime, config);
    limit = min(config.gross_limit, config.regime_gross_limit) if filtered else config.gross_limit;
    held_value = sum(qty * price_of(t) for (t, qty) in after_sells.items() if qty > 0);
    scale_buys(buys, max(0.0, limit * equity - held_value), "gross exposure", f"gross capped at {limit:.0%} ({why})");

    # 10: turnover, exits first.
    sell_value = sum(r.approved_qty * price_of(r.ticker) for r in sells);
    budget = config.turnover_limit * equity - book.turnover_today - sell_value;
    scale_buys(buys, max(0.0, budget), "daily turnover", f"{config.turnover_limit:.0%} of equity a day, exits first");
    return results;
}

"""Scale every live buy down together so their value fits `room`, flooring each to whole
shares, and record `rule` on each."""
def scale_buys(buys: list[GateResult], room: float, rule: str, detail: str) {
    live = [b for b in buys if b.alive()];
    asked = sum(b.approved_qty * b.price for b in live);
    factor = min(1.0, room / asked) if asked > 0.0 else 1.0;
    for b in live {
        b.apply(rule, int(math.floor(b.approved_qty * factor)), f"{detail}; buys scaled by {factor:.2f}" if factor < 1.0 else detail);
    }
}

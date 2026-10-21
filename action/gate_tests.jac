"""The risk gate (action/gate.jac): each rule's breach, and a Hypothesis property test that no
approved order set breaks any cap, over thousands of random portfolios and decisions
(TDD §14, testing)."""
import math;
import from hypothesis { HealthCheck, given, settings }
import from hypothesis { strategies }
import from action.gate {
    Book,
    BookPosition,
    GateConfig,
    GateResult,
    Instrument,
    Proposal,
    check_orders,
    regime_on
}
import from models.graph { OrderPurpose, OrderSide, RiskOutcome, TradeAction }
import from models.research { RegimeInputs }

glob CALM: RegimeInputs = RegimeInputs(spy_close=500.0, spy_sma_200=450.0, spy_vol_20=0.15, spy_as_of="2026-10-20");
glob STRESSED: RegimeInputs = RegimeInputs(spy_close=400.0, spy_sma_200=450.0, spy_vol_20=0.35, spy_as_of="2026-10-20");

def stock(ticker: str, price: float = 100.0, sector: str = "Tech") -> Instrument {
    return Instrument(ticker=ticker, price=price, sector=sector, trade_age_minutes=1.0, atr_14=2.0, volume_20=1000000.0);
}

def book(equity: float = 100000.0, positions: list[BookPosition] | None = None) -> Book {
    return Book(equity=equity, peak_equity=equity, positions={p.ticker: p for p in (positions or [])});
}

def buy(ticker: str, qty: int, conviction: float = 0.5) -> Proposal {
    return Proposal(ticker=ticker, action=TradeAction.BUY, side=OrderSide.BUY, qty=qty, conviction=conviction);
}

def sell(ticker: str, qty: int) -> Proposal {
    return Proposal(ticker=ticker, action=TradeAction.SELL, side=OrderSide.SELL, qty=qty, conviction=0.0);
}

def one(results: list[GateResult], ticker: str) -> GateResult {
    return [r for r in results if r.ticker == ticker][0];
}

test "an order inside every limit is approved with each rule recorded, and its stop is 2 ATR" {
    r = check_orders([buy("AAA", 50)], book(), {"AAA": stock("AAA")}, CALM)[0];
    assert r.outcome() == RiskOutcome.APPROVED and r.approved_qty == 50 and r.purpose == OrderPurpose.ENTRY;
    assert r.stop_distance == 4.0 and all(x.passed for x in r.rules);
    assert [x.rule for x in r.rules] == ["instrument checks", "earnings blackout", "drawdown breaker", "protective stop", "per-position cap", "liquidity", "new positions per day", "sector cap", "gross exposure", "daily turnover"];
}

test "instrument checks reject a cheap, untradable, stale, or unknown stock" {
    cheap = stock("CHP", price=5.0);
    closed = stock("CLS");
    closed.tradable = False;
    stale = stock("OLD");
    stale.trade_age_minutes = 40.0;
    results = check_orders([buy("CHP", 10), buy("CLS", 10), buy("OLD", 10), buy("NON", 10)], book(), {"CHP": cheap, "CLS": closed, "OLD": stale}, CALM);
    assert all(r.outcome() == RiskOutcome.REJECTED and r.rejected_by() == "instrument checks" for r in results);
}

test "the earnings blackout rejects a buy within two sessions of earnings, not three" {
    soon = stock("SOON");
    soon.sessions_to_earnings = 2;
    later = stock("LATE");
    later.sessions_to_earnings = 3;
    results = check_orders([buy("SOON", 10), buy("LATE", 10)], book(), {"SOON": soon, "LATE": later}, CALM);
    assert one(results, "SOON").rejected_by() == "earnings blackout";
    assert one(results, "LATE").outcome() == RiskOutcome.APPROVED;
}

test "the drawdown breaker halts buys, and exits still run" {
    held = book(positions=[BookPosition(ticker="OUT", qty=10, price=100.0)]);
    held.peak_equity = 112000.0;
    results = check_orders([buy("AAA", 10), sell("OUT", 10)], held, {"AAA": stock("AAA"), "OUT": stock("OUT")}, CALM);
    assert one(results, "AAA").rejected_by() == "drawdown breaker";
    assert one(results, "OUT").outcome() == RiskOutcome.APPROVED and one(results, "OUT").purpose == OrderPurpose.EXIT;
}

test "a buy without a usable ATR is rejected, since it could not get a stop" {
    flat = stock("AAA");
    flat.atr_14 = None;
    deep = stock("BBB", price=6.0);
    deep.atr_14 = 3.5;
    results = check_orders([buy("AAA", 10), buy("BBB", 10)], book(), {"AAA": flat, "BBB": deep}, CALM);
    assert all(r.rejected_by() == "protective stop" for r in results);
}

test "the per-position cap resizes a buy, counting shares already held" {
    held = book(positions=[BookPosition(ticker="AAA", qty=60, price=100.0, sector="Tech")]);
    r = check_orders([buy("AAA", 100)], held, {"AAA": stock("AAA")}, CALM)[0];
    assert r.purpose == OrderPurpose.ADD and r.approved_qty == 40 and r.outcome() == RiskOutcome.RESIZED;
    assert r.rejected_by() == "per-position cap";
}

test "liquidity resizes a buy to 1% of average daily volume" {
    thin = stock("AAA");
    thin.volume_20 = 2500.0;
    r = check_orders([buy("AAA", 50)], book(), {"AAA": thin}, CALM)[0];
    assert r.approved_qty == 25 and r.rejected_by() == "liquidity";
}

test "only three new positions a day are kept, the highest conviction first" {
    proposals = [buy("AAA", 10, 0.2), buy("BBB", 10, 0.9), buy("CCC", 10, 0.5), buy("DDD", 10, 0.7)];
    results = check_orders(proposals, book(), {t: stock(t, sector=t) for t in ["AAA", "BBB", "CCC", "DDD"]}, CALM);
    assert one(results, "AAA").rejected_by() == "new positions per day";
    assert all(one(results, t).outcome() == RiskOutcome.APPROVED for t in ["BBB", "CCC", "DDD"]);
    already = book();
    already.new_positions_today = 3;
    assert check_orders([buy("BBB", 10, 0.9)], already, {"BBB": stock("BBB")}, CALM)[0].rejected_by() == "new positions per day";
}

test "an add does not use a new-position slot" {
    held = book(positions=[BookPosition(ticker="AAA", qty=10, price=100.0)]);
    held.new_positions_today = 3;
    assert check_orders([buy("AAA", 10)], held, {"AAA": stock("AAA")}, CALM)[0].outcome() == RiskOutcome.APPROVED;
}

test "the sector cap fills in conviction order and resizes the lowest-conviction order" {
    held = book(positions=[BookPosition(ticker="H1", qty=200, price=100.0, sector="Tech")]);
    proposals = [buy("AAA", 80, 0.9), buy("BBB", 80, 0.4)];
    results = check_orders(proposals, held, {"H1": stock("H1"), "AAA": stock("AAA"), "BBB": stock("BBB")}, CALM);
    # Tech holds 20%; AAA's 8% fits, which leaves 2% (20 shares) for BBB.
    assert one(results, "AAA").approved_qty == 80;
    assert one(results, "BBB").approved_qty == 20 and one(results, "BBB").rejected_by() == "sector cap";
}

test "gross exposure scales every buy down together, and further under the regime filter" {
    held = book(positions=[BookPosition(ticker=f"H{i}", qty=100, price=100.0, sector=f"S{i}") for i in range(8)]);
    universe = {t: stock(t, sector=t) for t in ["AAA", "BBB"]} | {f"H{i}": stock(f"H{i}", sector=f"S{i}") for i in range(8)};
    results = check_orders([buy("AAA", 80, 0.9), buy("BBB", 80, 0.8)], held, universe, CALM);
    # Holdings are 80% of equity, so 10% is left for 16% of buys.
    assert one(results, "AAA").approved_qty == 50 and one(results, "BBB").approved_qty == 50;
    assert all(r.rejected_by() == "gross exposure" for r in results);
    stressed = check_orders([buy("AAA", 80, 0.9)], held, universe, STRESSED);
    assert stressed[0].outcome() == RiskOutcome.REJECTED and stressed[0].rejected_by() == "gross exposure";
}

test "the regime filter is on only when SPY is below its 200-day average and volatile, or unknown" {
    assert not regime_on(CALM, GateConfig())[0];
    assert regime_on(STRESSED, GateConfig())[0];
    assert not regime_on(RegimeInputs(spy_close=400.0, spy_sma_200=450.0, spy_vol_20=0.2), GateConfig())[0];
    assert regime_on(None, GateConfig())[0] and regime_on(RegimeInputs(), GateConfig())[0];
}

test "turnover lets exits go first and scales buys into what is left" {
    held = book(positions=[BookPosition(ticker="OUT", qty=200, price=100.0, sector="Energy")]);
    held.turnover_today = 2000.0;
    results = check_orders([sell("OUT", 200), buy("AAA", 80, 0.9), buy("BBB", 80, 0.9)], held, {"OUT": stock("OUT"), "AAA": stock("AAA", sector="A"), "BBB": stock("BBB", sector="B")}, CALM);
    # 25% of 100,000 less 2,000 already traded and the 20,000 exit leaves 3,000 for 16,000 of buys.
    assert one(results, "OUT").approved_qty == 200;
    assert one(results, "AAA").approved_qty == 15 and one(results, "BBB").approved_qty == 15;
    assert one(results, "AAA").rejected_by() == "daily turnover";
}

test "a sell is cut to the shares held, and refused only when the stock cannot trade" {
    held = book(positions=[BookPosition(ticker="AAA", qty=10, price=100.0), BookPosition(ticker="BBB", qty=10, price=100.0)]);
    halted = stock("BBB");
    halted.tradable = False;
    results = check_orders([sell("AAA", 25), Proposal(ticker="BBB", action=TradeAction.TRIM, side=OrderSide.SELL, qty=5, conviction=0.0)], held, {"AAA": stock("AAA"), "BBB": halted}, STRESSED);
    assert one(results, "AAA").approved_qty == 10 and one(results, "AAA").outcome() == RiskOutcome.RESIZED;
    assert one(results, "BBB").purpose == OrderPurpose.TRIM and one(results, "BBB").rejected_by() == "instrument checks";
}

"""Draw a random portfolio, instrument set, regime, and proposal set, run the gate, and
check that the approved orders break no rule. Most stocks are drawn valid, with one flaw at
a time on the rest, so that many buys reach the caps rather than an early rejection."""
def gate_never_breaks_a_cap(data: object) {
    config = GateConfig();
    draw = getattr(data, "draw");
    equity = draw(strategies.floats(min_value=1000.0, max_value=1000000.0));
    peak = equity * (draw(strategies.floats(min_value=1.0, max_value=1.3)) if draw(strategies.integers(min_value=0, max_value=4)) == 0 else 1.0);
    sectors = ["A", "B", "C", ""];
    tickers = [f"T{i}" for i in range(draw(strategies.integers(min_value=1, max_value=14)))];
    instruments: dict[str, Instrument] = {};
    positions: dict[str, BookPosition] = {};
    proposals: list[Proposal] = [];
    for t in tickers {
        price = draw(strategies.floats(min_value=1.0, max_value=900.0));
        sector = draw(strategies.sampled_from(sectors));
        flaw = draw(strategies.integers(min_value=0, max_value=11));
        instruments[t] = Instrument(
            ticker=t,
            price=price,
            sector=sector,
            tradable=flaw != 0,
            active=True,
            trade_age_minutes=draw(strategies.one_of(strategies.none(), strategies.floats(min_value=15.01, max_value=600.0))) if flaw == 1 else draw(strategies.floats(min_value=0.0, max_value=15.0)),
            atr_14=draw(strategies.one_of(strategies.none(), strategies.floats(min_value=price / 2.0, max_value=price))) if flaw == 2 else price * draw(strategies.floats(min_value=0.001, max_value=0.1)),
            volume_20=draw(strategies.one_of(strategies.none(), strategies.floats(min_value=0.0, max_value=1000.0))) if flaw == 3 else draw(strategies.floats(min_value=1e4, max_value=1e8)),
            sessions_to_earnings=draw(strategies.integers(min_value=0, max_value=2)) if flaw == 4 else draw(strategies.one_of(strategies.none(), strategies.integers(min_value=3, max_value=60)))
        );
        held = draw(strategies.integers(min_value=0, max_value=int(0.15 * equity / price) + 1)) if draw(strategies.booleans()) else 0;
        if held > 0 {
            positions[t] = BookPosition(ticker=t, qty=held, price=price, sector=sector);
        }
        side = draw(strategies.sampled_from(["buy", "buy", "sell", "none"]));
        if side == "buy" {
            proposals.append(Proposal(ticker=t, action=TradeAction.ADD if held else TradeAction.BUY, side=OrderSide.BUY, qty=draw(strategies.integers(min_value=1, max_value=int(0.3 * equity / price) + 2)), conviction=draw(strategies.floats(min_value=0.0, max_value=1.0))));
        } elif side == "sell" and held > 0 {
            proposals.append(Proposal(ticker=t, action=TradeAction.SELL, side=OrderSide.SELL, qty=draw(strategies.integers(min_value=1, max_value=held + 3)), conviction=0.0));
        }
    }
    regime = draw(strategies.sampled_from([CALM, STRESSED, None]));
    portfolio = Book(equity=equity, peak_equity=peak, positions=positions, new_positions_today=draw(strategies.integers(min_value=0, max_value=4)), turnover_today=draw(strategies.sampled_from([0.0, 0.0, 0.1 * equity, 0.3 * equity])));
    results = check_orders(proposals, portfolio, instruments, regime, config);

    eps = 1e-6 * equity;
    after = {t: p.qty for (t, p) in positions.items()};
    bought: list[GateResult] = [];
    (buy_value, sell_value) = (0.0, 0.0);
    for r in results {
        assert 0 <= r.approved_qty <= r.requested_qty;
        if r.side == OrderSide.SELL {
            assert r.approved_qty <= portfolio.held(r.ticker);
            if instruments[r.ticker].tradable {
                assert r.approved_qty == min(r.requested_qty, portfolio.held(r.ticker)), "an exit of a tradable stock was cut";
            }
            after[r.ticker] = after.get(r.ticker, 0) - r.approved_qty;
            sell_value += r.approved_qty * r.price;
        } elif r.approved_qty > 0 {
            found = instruments[r.ticker];
            assert found.tradable and found.price > config.min_price and found.trade_age_minutes is not None and found.trade_age_minutes <= config.max_trade_age_minutes;
            assert found.sessions_to_earnings is None or found.sessions_to_earnings > config.earnings_blackout_sessions;
            assert peak <= 0 or equity > peak * (1.0 - config.drawdown_halt);
            assert found.atr_14 is not None and found.price - 2.0 * found.atr_14 > 0 and r.stop_distance == 2.0 * found.atr_14;
            assert found.volume_20 is not None and r.approved_qty <= config.adv_fraction * found.volume_20;
            after[r.ticker] = after.get(r.ticker, 0) + r.approved_qty;
            buy_value += r.approved_qty * found.price;
            bought.append(r);
        }
    }
    if not bought {
        return;
    }
    value = {t: q * instruments[t].price for (t, q) in after.items() if q > 0};
    for r in bought {
        assert value[r.ticker] <= config.max_position_weight * equity + eps, "per-position cap broken";
    }
    for sector in {(instruments[r.ticker].sector or "unknown sector") for r in bought} {
        total = sum(v for (t, v) in value.items() if (instruments[t].sector or "unknown sector") == sector);
        assert total <= config.sector_cap * equity + eps, f"sector cap broken for {sector!r}";
    }
    limit = config.gross_limit if regime is CALM else config.regime_gross_limit;
    assert sum(value.values()) <= limit * equity + eps, "gross exposure broken";
    entries = [r for r in bought if r.purpose == OrderPurpose.ENTRY];
    assert len(entries) <= max(0, config.new_positions_per_day - portfolio.new_positions_today), "too many new positions";
    assert buy_value <= max(0.0, config.turnover_limit * equity - portfolio.turnover_today - sell_value) + eps, "turnover broken";
}

test "no approved order set breaks any cap, over thousands of random decision sets" {
    run = settings(max_examples=3000, deadline=None, suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large])(given(strategies.data())(gate_never_breaks_a_cap));
    run();
}

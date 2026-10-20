"""Position sizing (action/sizing.jac): the volatility ratio, the per-position cap before the
gross cap, whole shares, and the long-only actions."""
import from action.sizing { SizingCandidate, SizingConfig, size_positions }
import from models.graph { OrderSide, TradeAction }

def buy(ticker: str, conviction: float, vol: float, price: float = 100.0, held: int = 0) -> SizingCandidate {
    return SizingCandidate(ticker=ticker, action=TradeAction.ADD if held else TradeAction.BUY, conviction=conviction, price=price, realized_vol_20=vol, current_qty=held);
}

def holding(ticker: str, action: TradeAction, qty: int, price: float = 100.0, vol: float = 0.2) -> SizingCandidate {
    return SizingCandidate(ticker=ticker, action=action, conviction=0.0, price=price, realized_vol_20=vol, current_qty=qty);
}

test "a buy's weight is scale times conviction over its volatility relative to the median" {
    plan = size_positions([buy("AAA", 0.5, 0.2), buy("BBB", 0.5, 0.4), buy("CCC", 0.5, 0.3)], 100000.0);
    # Median volatility 0.3: AAA 0.08 * 0.5 / (0.2 / 0.3) = 6%, BBB 3%, CCC 4%.
    assert plan.position("AAA").target_qty == 60 and plan.position("BBB").target_qty == 30 and plan.position("CCC").target_qty == 40;
    assert all(p.side == OrderSide.BUY for p in plan.positions) and plan.gross_scale == 1.0;
    assert abs(plan.gross_weight - 0.13) < 1e-9;
}

test "the per-position cap applies before the gross cap" {
    plan = size_positions([buy("AAA", 1.0, 0.1), buy("BBB", 1.0, 0.4)], 100000.0);
    # AAA's raw weight is 0.08 * 1 / (0.1 / 0.25) = 20%, capped at 10%.
    assert plan.position("AAA").target_qty == 100 and plan.position("AAA").target_weight == 0.10;
}

test "buys shrink together to fit the gross limit, and holdings are never sold to make room" {
    held = [holding(f"H{i}", TradeAction.HOLD, 85) for i in range(10)];
    plan = size_positions(held + [buy("AAA", 1.0, 0.2), buy("BBB", 1.0, 0.2)], 100000.0);
    # Holdings are 85% of equity, so the two 8% buys share the 5% left.
    assert all(plan.position(f"H{i}").share_delta == 0 for i in range(10));
    assert plan.position("AAA").target_qty == 25 and plan.position("BBB").target_qty == 25;
    assert abs(plan.gross_scale - 5000.0 / 16000.0) < 1e-9 and plan.gross_weight <= 0.90 + 1e-9;
}

test "with no room left a buy sizes to zero shares" {
    held = [holding(f"H{i}", TradeAction.HOLD, 90) for i in range(10)];
    plan = size_positions(held + [buy("AAA", 1.0, 0.2)], 100000.0);
    assert plan.position("AAA").target_qty == 0 and plan.position("AAA").side is None and plan.gross_scale == 0.0;
}

test "an add only adds, up to the cap" {
    plan = size_positions([buy("AAA", 0.5, 0.2, held=30), buy("BBB", 0.5, 0.2, held=90)], 100000.0);
    # Both aim at 4%: AAA holds 3% and buys 10 shares; BBB already holds 9% and buys none.
    assert plan.position("AAA").share_delta == 10 and plan.position("BBB").share_delta == 0;
}

test "whole shares are floored" {
    plan = size_positions([buy("AAA", 0.5, 0.2, price=333.0)], 100000.0);
    # 4% of 100,000 is 4,000, which buys 12 shares at 333, not 12.01.
    assert plan.position("AAA").target_qty == 12;
}

test "sell exits, trim sells the configured fraction, and hold keeps every share" {
    plan = size_positions([holding("AAA", TradeAction.SELL, 33), holding("BBB", TradeAction.TRIM, 33), holding("CCC", TradeAction.HOLD, 33, price=303.03), holding("DDD", TradeAction.NO_ACTION, 7)], 100000.0);
    assert plan.position("AAA").share_delta == -33 and plan.position("AAA").side == OrderSide.SELL;
    assert plan.position("BBB").target_qty == 16 and plan.position("BBB").share_delta == -17;
    assert plan.position("CCC").share_delta == 0 and plan.position("CCC").side is None;
    assert plan.position("DDD").share_delta == 0;
    quarter = size_positions([holding("BBB", TradeAction.TRIM, 40)], 100000.0, SizingConfig(trim_fraction=0.25));
    assert quarter.position("BBB").share_delta == -10;
}

test "a buy without a price or a volatility buys nothing and says why" {
    plan = size_positions([buy("AAA", 0.5, 0.2), SizingCandidate(ticker="BBB", action=TradeAction.BUY, conviction=0.5, price=100.0), SizingCandidate(ticker="CCC", action=TradeAction.BUY, conviction=0.5, price=0.0, realized_vol_20=0.2)], 100000.0);
    assert plan.position("BBB").target_qty == 0 and "volatility" in plan.position("BBB").note;
    assert plan.position("CCC").target_qty == 0 and "price" in plan.position("CCC").note;
    assert plan.position("AAA").target_qty > 0;
}

test "bad inputs are refused" {
    bad = [
        ([buy("AAA", 0.5, 0.2)], 0.0),
        ([buy("AAA", 1.5, 0.2)], 1000.0),
        ([buy("AAA", 0.5, 0.2), buy("AAA", 0.5, 0.2)], 1000.0),
        ([holding("AAA", TradeAction.HOLD, -1)], 1000.0),
        ([holding("AAA", TradeAction.HOLD, 5, price=0.0)], 1000.0)
    ];
    for (candidates, equity) in bad {
        try {
            size_positions(candidates, equity);
            assert False, "bad sizing inputs were accepted";
        } except ValueError {}
    }
    for config in [lambda { SizingConfig(scale=-1.0); }, lambda { SizingConfig(max_position_weight=0.95); }, lambda { SizingConfig(trim_fraction=0.0); }] {
        try {
            config();
            assert False, "a bad config was accepted";
        } except ValueError {}
    }
}

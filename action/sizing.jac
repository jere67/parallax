"""Deterministic long-only position sizing (TDD §8, position sizing; FR-08).

The caller supplies the portfolio equity and, for every covered ticker and every open
holding, the final decision, its conviction, the latest price, the 20-day realized
volatility, and the shares held. This module returns target positions and whole-share
changes only; the risk gate (action/gate.jac) and the executor stay separate layers, and an
order exists only once the gate approves it.

- BUY and ADD aim at `scale * conviction / (volatility / median volatility)`, capped per
  position, and never below the current weight: an ADD only adds.
- SELL exits the whole position, and TRIM sells `trim_fraction` of it (TDD §7 leaves the
  trim size open; half is the starting value).
- HOLD and NO_ACTION keep exactly the shares held. Recomputing a held position's shares
  from a weight would trade a share either way on rounding alone.
- When the buys would take gross exposure over the limit, only the buys shrink, together;
  positions that are not buying are never sold to make room.
"""
import math;
import statistics;
import from models.graph { OrderSide, TradeAction }

# Bump with any change to the sizing rules or defaults, so a run records what sized it.
glob SIZING_VERSION: str = "2026-10-20.1";

obj SizingConfig {
    has scale: float = 0.08,
        max_position_weight: float = 0.10,
        gross_exposure_limit: float = 0.90,
        trim_fraction: float = 0.5;

    def postinit {
        if not math.isfinite(self.scale) or self.scale < 0.0 {
            raise ValueError("sizing scale must be nonnegative");
        }
        if not math.isfinite(self.max_position_weight) or self.max_position_weight <= 0.0 or self.max_position_weight > 1.0 {
            raise ValueError("max_position_weight must be in (0, 1]");
        }
        if not math.isfinite(self.gross_exposure_limit) or self.gross_exposure_limit <= 0.0 or self.gross_exposure_limit > 1.0 {
            raise ValueError("gross_exposure_limit must be in (0, 1]");
        }
        if self.max_position_weight > self.gross_exposure_limit {
            raise ValueError("max_position_weight cannot exceed gross_exposure_limit");
        }
        if not math.isfinite(self.trim_fraction) or self.trim_fraction <= 0.0 or self.trim_fraction > 1.0 {
            raise ValueError("trim_fraction must be in (0, 1]");
        }
    }
}

"""Sizing inputs for one ticker. Include every open holding, so gross exposure counts the
whole portfolio."""
obj SizingCandidate {
    has ticker: str,
        action: TradeAction,
        conviction: float,
        price: float;
    has realized_vol_20: float | None = None,
        current_qty: int = 0;
}

obj SizedPosition {
    has ticker: str,
        target_weight: float,
        target_qty: int,
        share_delta: int;
    has side: OrderSide | None = None,
        note: str = "";
}

obj SizingPlan {
    has equity: float,
        gross_weight: float,
        gross_scale: float,
        positions: list[SizedPosition];

    def position(ticker: str) -> SizedPosition {
        for p in self.positions {
            if p.ticker == ticker {
                return p;
            }
        }
        raise KeyError(ticker);
    }
}

"""Size every candidate from one portfolio snapshot."""
def size_positions(
    candidates: list[SizingCandidate],
    equity: float,
    config: SizingConfig = SizingConfig()
) -> SizingPlan {
    if not math.isfinite(equity) or equity <= 0.0 {
        raise ValueError("portfolio equity must be positive before sizing positions");
    }
    if len({c.ticker for c in candidates}) != len(candidates) {
        raise ValueError("sizing candidates must have unique tickers");
    }
    for c in candidates {
        if c.current_qty < 0 {
            raise ValueError(f"{c.ticker}: current quantity cannot be negative");
        }
        if not math.isfinite(c.conviction) or c.conviction < 0.0 or c.conviction > 1.0 {
            raise ValueError(f"{c.ticker}: conviction must be in [0, 1]");
        }
        if c.current_qty > 0 and not _priced(c) {
            raise ValueError(f"{c.ticker}: a held position needs a positive mark price");
        }
    }

    vols = [c.realized_vol_20 for c in candidates if c.realized_vol_20 is not None and math.isfinite(c.realized_vol_20) and c.realized_vol_20 > 0.0];
    median_vol = statistics.median(vols) if vols else None;
    kept_qty: dict[str, int] = {};
    notes: dict[str, str] = {};
    wanted: dict[str, float] = {};
    for c in candidates {
        match c.action {
            case TradeAction.SELL:
                kept_qty[c.ticker] = 0;
            case TradeAction.TRIM:
                kept_qty[c.ticker] = int(math.floor(c.current_qty * (1.0 - config.trim_fraction)));
            case TradeAction.BUY | TradeAction.ADD:
                kept_qty[c.ticker] = c.current_qty;
                volatility = c.realized_vol_20;
                if not _priced(c) {
                    notes[c.ticker] = "no positive price; nothing bought";
                } elif volatility is None or not math.isfinite(volatility) or volatility <= 0.0 or median_vol is None {
                    notes[c.ticker] = "no positive 20-day volatility; nothing bought";
                } else {
                    target = min(config.max_position_weight, config.scale * c.conviction / (volatility / median_vol));
                    wanted[c.ticker] = max(0.0, target * equity - c.current_qty * c.price);
                }
            case TradeAction.HOLD | TradeAction.NO_ACTION:
                kept_qty[c.ticker] = c.current_qty;
        }
    }

    kept_value = sum(kept_qty[c.ticker] * c.price for c in candidates if kept_qty[c.ticker] > 0);
    room = max(0.0, config.gross_exposure_limit * equity - kept_value);
    asked = sum(wanted.values());
    scale = min(1.0, room / asked) if asked > 0.0 else 1.0;

    positions: list[SizedPosition] = [];
    gross = 0.0;
    for c in candidates {
        target_qty = kept_qty[c.ticker];
        if c.ticker in wanted {
            target_qty += int(math.floor(wanted[c.ticker] * scale / c.price));
        }
        delta = target_qty - c.current_qty;
        weight = target_qty * c.price / equity if target_qty > 0 else 0.0;
        gross += weight;
        positions.append(SizedPosition(
            ticker=c.ticker,
            target_weight=weight,
            target_qty=target_qty,
            share_delta=delta,
            side=OrderSide.BUY if delta > 0 else OrderSide.SELL if delta < 0 else None,
            note=notes.get(c.ticker, "")
        ));
    }
    return SizingPlan(equity=equity, gross_weight=gross, gross_scale=scale, positions=positions);
}

def _priced(c: SizingCandidate) -> bool {
    return math.isfinite(c.price) and c.price > 0.0;
}

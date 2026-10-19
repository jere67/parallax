"""Deterministic long-only position sizing (TDD §8, FR-08).

The caller supplies the portfolio equity, every covered ticker's latest price and
20-day realized volatility, the final decision and current share count. This module
returns target positions and whole-share changes only; the risk gate and executor
remain separate layers and must approve orders before submission.
"""
import math;
import statistics;
import from models.graph { OrderSide, TradeAction }

obj SizingConfig {
    has scale: float = 0.08,
        max_position_weight: float = 0.10,
        gross_exposure_limit: float = 0.90;

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
    }
}

"""Sizing inputs for one covered ticker. Include every open holding so gross exposure
accounts for the full portfolio. `trim_target_weight` is optional because the TDD does not
specify a fixed trim fraction; when omitted, a TRIM keeps the current weight unless a
portfolio cap requires a reduction.
"""
obj SizingCandidate {
    has ticker: str,
        action: TradeAction,
        conviction: float,
        price: float;
    has realized_vol_20: float | None = None,
        current_qty: int = 0,
        trim_target_weight: float | None = None;
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
}

"""Size all covered tickers from one portfolio snapshot.

For BUY/ADD, raw weight is `scale * conviction / (ticker_volatility / median_volatility)`.
The per-position cap is applied before the portfolio-wide gross cap. Existing positions
remain long-only, and target quantities are floored to whole shares.
"""
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

    valid_vols = [c.realized_vol_20 for c in candidates if c.realized_vol_20 is not None and math.isfinite(c.realized_vol_20) and c.realized_vol_20 > 0.0];
    median_vol = statistics.median(valid_vols) if valid_vols else None;
    weights: dict[str, tuple[float, str]] = {};

    for candidate in candidates {
        if candidate.current_qty < 0 {
            raise ValueError(f"{candidate.ticker}: current quantity cannot be negative");
        }
        if not math.isfinite(candidate.conviction) or candidate.conviction < 0.0 or candidate.conviction > 1.0 {
            raise ValueError(f"{candidate.ticker}: conviction must be in [0, 1]");
        }
        if not math.isfinite(candidate.price) or candidate.price <= 0.0 {
            if candidate.current_qty > 0 {
                raise ValueError(f"{candidate.ticker}: a held position needs a positive mark price");
            }
            weights[candidate.ticker] = (0.0, "no positive price; no position sized");
            continue;
        }

        current_weight = candidate.current_qty * candidate.price / equity;
        note = "";
        match candidate.action {
            case TradeAction.SELL:
                target = 0.0;
            case TradeAction.BUY | TradeAction.ADD:
                volatility = candidate.realized_vol_20;
                if volatility is None or not math.isfinite(volatility) or volatility <= 0.0 or median_vol is None {
                    target = current_weight;
                    note = "no positive 20-day volatility; kept the current target";
                } else {
                    raw = config.scale * candidate.conviction / (volatility / median_vol);
                    target = min(config.max_position_weight, max(current_weight, raw));
                }
            case TradeAction.TRIM:
                if candidate.trim_target_weight is None {
                    target = current_weight;
                    note = "trim quantity is unspecified; kept the current target";
                } else {
                    if not math.isfinite(candidate.trim_target_weight) or candidate.trim_target_weight < 0.0 or candidate.trim_target_weight > 1.0 {
                        raise ValueError(f"{candidate.ticker}: trim_target_weight must be in [0, 1]");
                    }
                    target = min(current_weight, candidate.trim_target_weight);
                }
            case TradeAction.HOLD | TradeAction.NO_ACTION:
                target = current_weight;
        }
        weights[candidate.ticker] = (min(config.max_position_weight, max(0.0, target)), note);
    }

    unscaled_gross = sum(weight for (weight, _) in weights.values());
    scale = min(1.0, config.gross_exposure_limit / unscaled_gross) if unscaled_gross > 0.0 else 1.0;
    positions: list[SizedPosition] = [];
    gross_weight = 0.0;
    for candidate in candidates {
        (weight, note) = weights[candidate.ticker];
        target_weight = weight * scale;
        target_qty = int(math.floor(equity * target_weight / candidate.price)) if math.isfinite(candidate.price) and candidate.price > 0.0 else 0;
        delta = target_qty - candidate.current_qty;
        side = OrderSide.BUY if delta > 0 else OrderSide.SELL if delta < 0 else None;
        positions.append(SizedPosition(
            ticker=candidate.ticker,
            target_weight=target_weight,
            target_qty=target_qty,
            share_delta=delta,
            side=side,
            note=note
        ));
        gross_weight += target_weight;
    }
    return SizingPlan(equity=equity, gross_weight=gross_weight, gross_scale=scale, positions=positions);
}

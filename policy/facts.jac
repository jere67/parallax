"""The facts a policy's rules read about one stock in one run (analysis/policy.jac, METRICS),
built the same way whether they come from a live run's collection or from a stored run's
records, so a replay sees what the run saw.

A run stores each covered stock's figures on its Coverage; runs before policies existed lack
the indicators, so those metrics stay unknown in a replay and rules on them are skipped.
"""
import from datetime { date, timedelta }
import from analysis.consensus { Consensus }
import from analysis.policy { Facts }
import from models.graph { Coverage }
import from models.research { RegimeInputs }
import from research.indicators { Technicals }

"""One stock's figures on the run date: identity, screen, price indicators, and calendar."""
obj StockFacts {
    has ticker: str;
    has sector: str = "",
        last_close: float = 0.0,
        screen_score: float | None = None,
        rsi_14: float | None = None,
        momentum_20: float | None = None,
        momentum_60: float | None = None,
        sma_50: float | None = None,
        sma_200: float | None = None,
        range_52w_position: float | None = None,
        rs_spy_20: float | None = None,
        realized_vol_20: float | None = None,
        atr_14: float | None = None,
        sessions_to_earnings: int | None = None;
}

"""The market on the run date: the Macro agent's regime ("" when there was no brief) and
SPY's figures."""
obj MarketFacts {
    has regime: str = "";
    has inputs: RegimeInputs | None = None;
}

"""A held position: its average entry price and the trading date it opened."""
obj Entry {
    has avg_entry_price: float,
        opened_day: str;
}

"""A stock's figures from a live run's collected technicals."""
def stock_from_technicals(ticker: str, sector: str, screen_score: float | None, stock: Technicals | None, sessions_to_earnings: int | None) -> StockFacts {
    found = StockFacts(ticker=ticker, sector=sector, screen_score=screen_score, sessions_to_earnings=sessions_to_earnings);
    if stock is not None {
        found.last_close = stock.close;
        found.rsi_14 = stock.rsi_14;
        found.momentum_20 = stock.momentum_20;
        found.momentum_60 = stock.momentum_60;
        found.sma_50 = stock.sma_50;
        found.sma_200 = stock.sma_200;
        found.range_52w_position = stock.range_52w_position;
        found.rs_spy_20 = stock.rs_spy_20;
        found.realized_vol_20 = stock.realized_vol_20;
        found.atr_14 = stock.atr_14;
    }
    return found;
}

"""A stock's figures as a stored run recorded them."""
def stock_from_coverage(cov: Coverage) -> StockFacts {
    return StockFacts(
        ticker=cov.ticker,
        sector=cov.sector,
        last_close=cov.last_close,
        screen_score=cov.screen_score if cov.reason.value == "screen" else None,
        rsi_14=cov.rsi_14,
        momentum_20=cov.momentum_20,
        momentum_60=cov.momentum_60,
        sma_50=cov.sma_50,
        sma_200=cov.sma_200,
        range_52w_position=cov.range_52w_position,
        rs_spy_20=cov.rs_spy_20,
        realized_vol_20=cov.realized_vol_20,
        atr_14=cov.atr_14,
        sessions_to_earnings=cov.sessions_to_earnings
    );
}

"""Everything a rule can read about `stock` on `run_day`, before the panel: the panel's
figures come in with `add_panel`. `position` is set when the stock is held."""
def stock_facts(stock: StockFacts, market: MarketFacts, position: Entry | None, run_day: str) -> Facts {
    found = Facts();
    found.put_word("ticker", stock.ticker);
    found.put_word("sector", stock.sector);
    found.put_word("regime", market.regime);
    found.put("screen_score", stock.screen_score);
    found.put("rsi_14", stock.rsi_14);
    found.put("momentum_20", stock.momentum_20);
    found.put("momentum_60", stock.momentum_60);
    found.put("range_52w_position", stock.range_52w_position);
    found.put("rs_spy_20", stock.rs_spy_20);
    found.put("realized_vol_20", stock.realized_vol_20);
    found.put("sessions_to_earnings", float(stock.sessions_to_earnings) if stock.sessions_to_earnings is not None else None);
    close = stock.last_close;
    if close > 0 {
        found.put("price_vs_sma_50", _gap(close, stock.sma_50));
        found.put("price_vs_sma_200", _gap(close, stock.sma_200));
        found.put("atr_pct", stock.atr_14 / close if stock.atr_14 is not None else None);
    }
    inputs = market.inputs;
    if inputs is not None and inputs.spy_close is not None {
        found.put("spy_vs_sma_200", _gap(inputs.spy_close, inputs.spy_sma_200));
    }
    if position is not None {
        if position.avg_entry_price > 0 and close > 0 {
            found.put("return_since_entry", close / position.avg_entry_price - 1.0);
        }
        if position.opened_day {
            found.put("sessions_held", float(weekdays_between(position.opened_day, run_day)));
        }
    }
    return found;
}

"""Add the panel's figures to `facts`: C, A, the interval's low end, conviction, and each
specialist's mean score (a specialist that abstained has none)."""
def add_panel(facts: Facts, panel: Consensus | None) {
    if panel is None {
        return;
    }
    facts.put("score", panel.score);
    facts.put("agreement", panel.agreement);
    facts.put("ci_low", panel.ci_low);
    facts.put("conviction", panel.conviction());
    for (name, value) in panel.specialist_scores.items() {
        facts.put(f"{name}_score", value);
    }
}

"""Weekdays after `start` up to and including `end` ("YYYY-MM-DD"): sessions held, counting
holidays as sessions. 0 when `end` is not after `start` or a date does not parse."""
def weekdays_between(start: str, end: str) -> int {
    try {
        (a, b) = (date.fromisoformat(start[:10]), date.fromisoformat(end[:10]));
    } except ValueError {
        return 0;
    }
    if b <= a {
        return 0;
    }
    whole = (b - a).days // 7;
    count = whole * 5;
    day = a + timedelta(days=whole * 7);
    while day < b {
        day += timedelta(days=1);
        if day.weekday() < 5 {
            count += 1;
        }
    }
    return count;
}

def _gap(price: float, average: float | None) -> float | None {
    return price / average - 1.0 if average is not None and average > 0 else None;
}

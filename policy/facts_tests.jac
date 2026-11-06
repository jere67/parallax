"""A rule reads the same facts from a live run's technicals and a stored run's coverage."""
import from analysis.consensus { Consensus }
import from analysis.policy { METRIC_BY_NAME }
import from models.graph { Coverage, CoverageReason }
import from models.research { RegimeInputs }
import from policy.facts { Entry, MarketFacts, StockFacts, add_panel, stock_facts, stock_from_coverage, weekdays_between }

def full_stock -> StockFacts {
    return StockFacts(ticker="AAPL", sector="Information Technology", last_close=110.0, screen_score=0.7, rsi_14=72.0, momentum_20=0.05, momentum_60=0.12, sma_50=100.0, sma_200=88.0, range_52w_position=0.9, rs_spy_20=0.02, realized_vol_20=0.3, atr_14=2.2, sessions_to_earnings=4);
}

test "every metric comes from the stock, the market, the position, or the panel" {
    market = MarketFacts(regime="RISK_ON", inputs=RegimeInputs(spy_close=550.0, spy_sma_200=500.0));
    found = stock_facts(full_stock(), market, Entry(avg_entry_price=100.0, opened_day="2026-10-26"), "2026-11-02");
    add_panel(found, Consensus(score=0.4, agreement=0.8, ci_low=0.1, ci_high=0.6, specialist_scores={s: 0.1 for s in ["fundamentals", "technical", "news", "macro", "flow"]}));
    for name in METRIC_BY_NAME {
        assert name in found.numbers or name in found.words, name;
    }
    assert round(found.numbers["price_vs_sma_50"], 9) == 0.1 and round(found.numbers["price_vs_sma_200"], 9) == 0.25;
    assert round(found.numbers["atr_pct"], 9) == 0.02 and round(found.numbers["spy_vs_sma_200"], 9) == 0.1;
    assert round(found.numbers["return_since_entry"], 9) == 0.1 and found.numbers["sessions_held"] == 5.0;
    assert round(found.numbers["conviction"], 9) == 0.32;
    assert found.words == {"ticker": "AAPL", "sector": "Information Technology", "regime": "RISK_ON"};
}

test "a missing figure stays unknown, never zero" {
    found = stock_facts(StockFacts(ticker="AAPL"), MarketFacts(), None, "2026-11-02");
    assert found.numbers == {} and found.words == {"ticker": "AAPL"};
    add_panel(found, None);
    assert found.numbers == {};
}

test "a stored coverage gives the run's figures, and only a screen pick has a screen score" {
    cov = Coverage(ticker="XOM", sector="Energy", reason=CoverageReason.SCREEN, screen_score=0.6, last_close=120.0, rsi_14=55.0, atr_14=2.4);
    root ++> cov;
    stock = stock_from_coverage(cov);
    assert (stock.ticker, stock.sector, stock.screen_score, stock.rsi_14) == ("XOM", "Energy", 0.6, 55.0);
    held = Coverage(ticker="XOM", sector="Energy", reason=CoverageReason.HELD, screen_score=0.6);
    root ++> held;
    assert stock_from_coverage(held).screen_score is None;
}

test "sessions held count weekdays after the opening date" {
    assert weekdays_between("2026-11-02", "2026-11-02") == 0;
    assert weekdays_between("2026-11-02", "2026-11-03") == 1;
    # Friday to Monday is one session, and four whole weeks are twenty.
    assert weekdays_between("2026-10-30", "2026-11-02") == 1;
    assert weekdays_between("2026-10-05", "2026-11-02") == 20;
    assert weekdays_between("not a date", "2026-11-02") == 0;
    assert weekdays_between("2026-11-03", "2026-11-02") == 0;
    assert weekdays_between("2026-10-30T14:00:00+00:00", "2026-11-02") == 1;
}

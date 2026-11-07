"""The screener's row for a stock: ratios worked out from what is known, and nothing from what is not."""
import from datetime { date }
import from market.analysts { AnalystRecord }
import from market.listings { Listing }
import from market.prices { PriceStats, Quote }
import from market.rows { MAX_DAILY_TURNOVER, build_row, build_rows, change, days_until, filed_shares, plausible, previous_close, ratio }
import from market.state { CompanySummary, EarningsDates, MarketState }

glob TODAY: date = date(2026, 11, 5);

def listing(kind: str = "common") -> Listing {
    return Listing(symbol="X", name="X Corp", cik="1", exchange="Nasdaq", kind=kind);
}

def quote(price: float = 100.0) -> Quote {
    return Quote(symbol="X", day="2026-11-05", price=price, prev_close=80.0, open=90.0, volume=1000.0);
}

def company(values: dict[str, float]) -> CompanySummary {
    return CompanySummary(cik="1", sic=3571, sic_description="ELECTRONIC COMPUTERS", values=values);
}

test "helpers leave out what they cannot divide" {
    assert ratio(1.0, 0.0) is None and ratio(None, 1.0) is None and ratio(1.0, -1.0) is None;
    assert change(110.0, 100.0) == 0.10000000000000009;
    assert change(None, 100.0) is None and change(1.0, 0.0) is None;
    assert days_until("2026-11-08", TODAY) == 3.0;
    assert days_until("", TODAY) is None and days_until("soon", TODAY) is None;
}

test "a stock with nothing yet still has a row" {
    found = build_row(listing(), None, None, None, None, None, TODAY);
    assert found["symbol"] == "X" and found["price"] is None and found["market_cap"] is None and found["pe"] is None;
}

test "market cap and P/E come from the company's shares and the trailing year" {
    found = build_row(listing(), quote(), None, company({"shares": 1.0e6, "net_income_ttm": 5.0e6, "revenue_ttm": 2.0e7}), None, None, TODAY);
    assert found["market_cap"] == 1.0e8;
    assert found["pe"] == 20.0;
    assert found["ps"] == 5.0;
    assert abs(found["change_pct"] - 0.25) < 1e-9;
    assert found["sector"] == "Information Technology";
    assert found["industry"] == "Electronic computers";
}

test "a loss has no P/E" {
    found = build_row(listing(), quote(), None, company({"shares": 1.0e6, "net_income_ttm": -5.0e6}), None, None, TODAY);
    assert found["market_cap"] == 1.0e8 and found["pe"] is None;
}

test "a depositary receipt's cap comes from its own implied units, not the filer's shares" {
    analyst = AnalystRecord(symbol="X", checked="2026-11-05", implied_shares=20.0);
    found = build_row(listing("adr"), quote(), None, company({"shares": 999.0, "net_income_ttm": 100.0}), analyst, None, TODAY);
    assert found["market_cap"] == 2000.0;
    assert found["pe"] == 20.0;
}

test "performance is against each anchor, and earnings dates count from today" {
    stats = PriceStats(symbol="X", day="2026-11-05", anchors={"1m": 50.0, "ytd": 200.0});
    dates = EarningsDates(last_day="2026-10-30", next_day="2026-11-10");
    found = build_row(listing(), quote(), stats, None, None, dates, TODAY);
    assert found["perf_1m"] == 1.0;
    assert found["perf_ytd"] == -0.5;
    assert found["perf_1y"] is None;
    assert found["earnings_next_in"] == 5.0;
    assert found["earnings_last_in"] == -6.0;
}

def stats_at(day: str, last: float, prior: float) -> PriceStats {
    return PriceStats(symbol="X", day=day, last_close=last, prior_close=prior);
}

test "a price below zero is no base for a return" {
    assert change(1.0, -5.0) is None;
}

test "today's move ignores a split the snapshot's close is from before" {
    split = Quote(symbol="X", day="2026-11-05", price=1.31, prev_close=0.04, open=1.3, volume=1.0);
    assert previous_close(split, stats_at("2026-11-05", 1.31, 1.25)) == 1.25;
    assert previous_close(split, stats_at("2026-11-04", 1.26, 1.2)) == 1.26;
    row = build_row(listing(), split, stats_at("2026-11-05", 1.31, 1.25), None, None, None, TODAY);
    moved: any = row["change_pct"];
    gap: any = row["gap_pct"];
    assert abs(moved - 0.048) < 0.001;
    assert abs(gap - 0.04) < 0.001;
}

test "today's real move stands, whatever the adjusted close says" {
    plain = Quote(symbol="X", day="2026-11-05", price=50.0, prev_close=100.0, open=60.0, volume=1.0);
    assert previous_close(plain, stats_at("2026-11-05", 50.0, 99.0)) == 100.0;
    assert previous_close(plain, stats_at("2026-11-06", 50.0, 20.0)) == 100.0;
    assert previous_close(plain, None) == 100.0;
}

test "a filed share count that cannot be the company's is unknown" {
    assert filed_shares({"shares": 1000000.0}, 500000.0) == 1000000.0;
    assert filed_shares({"shares": 100.0}, None) is None;
    assert filed_shares({"shares": 180049.0}, 180049.0 * MAX_DAILY_TURNOVER + 1.0) is None;
    assert filed_shares({}, 1.0) is None;
    row = build_row(listing(), quote(), None, company({"shares": 1.0, "net_income_ttm": 5.0e6}), None, None, TODAY);
    assert row["market_cap"] is None and row["pe"] is None;
}

test "a dividend no stock pays is unknown, not a yield, and no dividend is zero" {
    wild = build_row(listing(), quote(20.0), None, company({"dividends_ps_ttm": 440000.0, "eps_ttm": 1.0}), None, None, TODAY);
    assert wild["dividends_ps_ttm"] is None and wild["dividend_yield"] is None and wild["payout_ratio"] is None;
    negative = build_row(listing(), quote(20.0), None, company({"dividends_ps_ttm": -0.5}), None, None, TODAY);
    assert negative["dividend_yield"] is None;
    fair = build_row(listing(), quote(20.0), None, company({"dividends_ps_ttm": 1.0, "eps_ttm": 2.0}), None, None, TODAY);
    assert fair["dividend_yield"] == 0.05 and fair["payout_ratio"] == 0.5;
    none = build_row(listing(), quote(20.0), None, company({"net_income_ttm": 1.0}), None, None, TODAY);
    assert none["dividend_yield"] == 0.0;
}

test "an EPS many times the price is from before a reverse split" {
    row = build_row(listing(), quote(0.5), None, company({"eps_ttm": 2983744.0}), None, None, TODAY);
    assert row["eps_ttm"] is None;
    loss = build_row(listing(), quote(10.0), None, company({"eps_ttm": -3.0}), None, None, TODAY);
    assert loss["eps_ttm"] == -3.0;
}

test "a ratio outside its believable range is unknown" {
    assert plausible("gross_margin", 0.5) == 0.5 and plausible("gross_margin", 145.0) is None;
    assert plausible("beta", None) is None and plausible("beta", 21.0) is None;
    values = {"revenue_ttm": 1.0e6, "gross_profit_ttm": 1.3e9, "net_income_ttm": 1.0e8, "shares": 1.0e6};
    row = build_row(listing(), quote(), None, company(values), None, None, TODAY);
    assert row["gross_margin"] is None and row["net_margin"] is None;
    assert row["market_cap"] == 1.0e8;
}

test "a P/E too small to believe leaves no PEG" {
    values = {"net_income_ttm": 1.0e10, "shares": 1.0e6, "eps_growth": 0.5};
    row = build_row(listing(), quote(), None, company(values), None, None, TODAY);
    assert row["pe"] is None and row["peg"] is None;
}

test "a fund the sweep has found drops out of the table" {
    state = MarketState();
    state.listings = {
        "GLD": Listing(symbol="GLD", name="Gold Holdings", cik="1", exchange="NYSE", kind="common"),
        "X": Listing(symbol="X", name="X Corp", cik="2", exchange="Nasdaq", kind="common"),
        "NEW": Listing(symbol="NEW", name="New Trust", cik="3", exchange="Nasdaq", kind="common")
    };
    state.companies = {"1": CompanySummary(cik="1", sic=6221), "2": CompanySummary(cik="2", sic=3571)};
    assert sorted([str(r["symbol"]) for r in build_rows(state, TODAY)]) == ["NEW", "X"];
}

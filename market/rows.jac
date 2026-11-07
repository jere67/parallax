"""A stock's flat row: one number or word per field, merged from its listing, quote, price stats,
company figures, analyst record, and earnings dates.

Price-based figures are worked out here, so a market cap, a P/E, or a return follows the latest
quote between the slower sweeps. A figure that cannot be worked out is None, never zero. Ratios
that divide by a loss or negative equity are None too, as they would otherwise read as cheap.
"""
import from datetime { date }
import from market.analysts { AnalystRecord }
import from market.prices { PriceStats, Quote, rating_label, technical_score, technical_signals }
import from market.sectors { sector_of }
import from market.state { CompanySummary, EarningsDates, MarketState }
import from market.listings { Listing, is_fund }

# How far a snapshot's previous close may sit from the adjusted one before it is taken for one from
# before a split or spin-off made that morning.
glob SPLIT_GAP: float = 1.25;
# A filer's cover page can count the shares of a holding company before its IPO, or give them in
# thousands. Few stocks are this small, and none trades twice its whole count a day for weeks.
glob MIN_FILED_SHARES: float = 50000.0;
glob MAX_DAILY_TURNOVER: float = 2.0;
# Dividends beyond this share of the price are a preferred share's or a mis-scaled filing's.
glob MAX_DIVIDEND_YIELD: float = 0.3;
# An EPS many times the price is from before a reverse split the filing has not restated.
glob MAX_EPS_TO_PRICE: float = 20.0;
# Each ratio's believable range. XBRL carries filers' scale errors and stray tags, and one of them
# would otherwise top every sort, so a ratio outside its range is unknown rather than shown.
glob PLAUSIBLE: dict[str, tuple[float, float]] = {
    "payout_ratio": (0.0, 10.0),
    "gross_margin": (-10.0, 1.0),
    "operating_margin": (-100.0, 10.0),
    "net_margin": (-100.0, 10.0),
    "fcf_margin": (-100.0, 10.0),
    "roe": (-50.0, 50.0),
    "roa": (-10.0, 2.0),
    "pe": (0.5, 20000.0),
    "earnings_yield": (-100.0, 2.0),
    "ps": (0.001, 20000.0),
    "pb": (0.001, 5000.0),
    "ev_revenue": (-1000.0, 20000.0),
    "debt_to_equity": (0.0, 500.0),
    "current_ratio": (0.0, 500.0),
    "beta": (-5.0, 10.0),
    "atr_pct": (0.0, 2.0),
    "volatility": (0.0, 10.0)
};

"""`value` when it is inside `key`'s believable range, else None."""
def plausible(key: str, value: float | str | None) -> float | None {
    (low, high) = PLAUSIBLE[key];
    return value if isinstance(value, float) and low <= value <= high else None;
}

"""`a / b` when both exist and `b` is positive."""
def ratio(a: float | None, b: float | None) -> float | None {
    return a / b if a is not None and b is not None and b > 0 else None;
}

def change(now: float | None, before: float | None) -> float | None {
    return now / before - 1.0 if now is not None and before is not None and before > 0 else None;
}

"""The close to measure today's move from. A snapshot's own previous close is the one traded on
that day, so a split or spin-off made since reads as a move of that size; the adjusted close, which
is a dividend off at most, replaces it when the two are far apart."""
def previous_close(quote: Quote, stats: PriceStats | None) -> float | None {
    adjusted: float | None = None;
    if stats is not None {
        adjusted = stats.prior_close if stats.day == quote.day else (stats.last_close if stats.day < quote.day else None);
    }
    before = quote.prev_close;
    if adjusted and (not before or not 1.0 / SPLIT_GAP <= before / adjusted <= SPLIT_GAP) {
        return adjusted;
    }
    return before;
}

"""The shares a filing reports, or None when the count cannot be the company's whole."""
def filed_shares(values: dict[str, float], average_volume: float | None) -> float | None {
    shares = values.get("shares");
    if shares is None or shares < MIN_FILED_SHARES {
        return None;
    }
    return None if average_volume and average_volume > shares * MAX_DAILY_TURNOVER else shares;
}

def days_until(day: str, today: date) -> float | None {
    if not day {
        return None;
    }
    try {
        return float((date.fromisoformat(day) - today).days);
    } except ValueError {
        return None;
    }
}

"""Every field for one stock as of `today`."""
def build_row(
    listing: Listing,
    quote: Quote | None,
    stats: PriceStats | None,
    company: CompanySummary | None,
    analyst: AnalystRecord | None,
    dates: EarningsDates | None,
    today: date
) -> dict[str, float | str | None] {
    values: dict[str, float] = company.values if company else {};
    price: float | None = quote.price if quote else None;
    row: dict[str, float | str | None] = {
        "symbol": listing.symbol,
        "name": listing.name,
        "exchange": listing.exchange,
        "kind": listing.kind,
        "sp500": "S&P 500" if listing.sp500 else "",
        "sector": listing.sector or sector_of(company.sic if company else None),
        "industry": listing.industry or (company.sic_description.capitalize() if company else "")
    };

    # Quote.
    row["price"] = price;
    before = previous_close(quote, stats) if quote else None;
    row["change_pct"] = change(price, before);
    row["change"] = price - before if price is not None and before else None;
    row["gap_pct"] = change(quote.open, before) if quote else None;
    row["day_range_pct"] = ratio(quote.high - quote.low, quote.low) if quote and quote.high is not None and quote.low is not None else None;
    row["volume"] = quote.volume if quote else None;
    average_volume = stats.average_volume if stats else None;
    row["average_volume"] = average_volume;
    row["rel_volume"] = ratio(quote.volume, average_volume) if quote else None;
    row["dollar_volume"] = quote.volume * price if quote and quote.volume is not None and price is not None else None;
    row["ext_price"] = quote.ext_price if quote else None;
    row["ext_change_pct"] = change(quote.ext_price, price) if quote else None;
    row["ext_change"] = quote.ext_price - price if quote and quote.ext_price is not None and price is not None else None;
    row["quote_day"] = quote.day if quote else "";

    # Performance and technicals.
    anchors: dict[str, float] = stats.anchors if stats else {};
    for period in ("1w", "1m", "3m", "6m", "ytd", "1y") {
        row[f"perf_{period}"] = change(price, anchors.get(period));
    }
    row["volatility"] = stats.volatility if stats else None;
    row["high_52w"] = stats.high_52w if stats else None;
    row["low_52w"] = stats.low_52w if stats else None;
    row["from_high_pct"] = change(price, stats.high_52w) if stats else None;
    row["from_low_pct"] = change(price, stats.low_52w) if stats else None;
    row["rsi_14"] = stats.rsi_14 if stats else None;
    row["macd_hist"] = stats.macd_hist if stats else None;
    row["atr_pct"] = stats.atr_pct if stats else None;
    row["sma_20_pct"] = change(price, stats.sma_20) if stats else None;
    row["sma_50_pct"] = change(price, stats.sma_50) if stats else None;
    row["sma_200_pct"] = change(price, stats.sma_200) if stats else None;
    row["beta"] = stats.beta if stats else None;
    tech = technical_score(technical_signals(price, stats)) if stats is not None and price is not None else None;
    row["tech_score"] = tech;
    row["tech_rating"] = rating_label(tech);

    # Size. A Finnhub share count covers share classes and ADRs; SEC's covers the rest, but an ADR's
    # filed shares are not its ADRs, so an ADR waits for Finnhub.
    shares: float | None = analyst.implied_shares if analyst else None;
    if shares is None and listing.kind != "adr" {
        shares = filed_shares(values, average_volume);
    }
    market_cap = shares * price if shares is not None and price is not None else None;
    row["shares"] = shares;
    row["market_cap"] = market_cap;

    # Income, in dollars for the trailing year unless named otherwise.
    revenue = values.get("revenue_ttm");
    gross = values.get("gross_profit_ttm");
    operating = values.get("operating_income_ttm");
    net = values.get("net_income_ttm");
    cash_flow = values.get("operating_cash_flow_ttm");
    capex = values.get("capital_expenditure_ttm");
    free_cash = values.get("free_cash_flow_ttm");
    assets = values.get("total_assets");
    liabilities = values.get("total_liabilities");
    equity = values.get("stockholders_equity");
    cash = values.get("cash");
    debt = values.get("debt", values.get("long_term_debt"));
    current_assets = values.get("current_assets");
    current_liabilities = values.get("current_liabilities");
    eps = values.get("eps_ttm");
    if eps is not None and price and abs(eps) > price * MAX_EPS_TO_PRICE {
        eps = None;
    }
    dividends = values.get("dividends_ps_ttm");
    if dividends is not None and (dividends < 0 or (price and dividends / price > MAX_DIVIDEND_YIELD)) {
        dividends = None;
    }
    row["revenue_ttm"] = revenue;
    row["gross_profit_ttm"] = gross;
    row["operating_income_ttm"] = operating;
    row["net_income_ttm"] = net;
    row["research_ttm"] = values.get("research_ttm");
    row["revenue_fy"] = values.get("revenue_fy");
    row["net_income_fy"] = values.get("net_income_fy");
    row["revenue_growth"] = values.get("revenue_growth");
    row["net_income_growth"] = values.get("net_income_growth");
    row["eps_growth"] = values.get("eps_growth");
    row["eps_ttm"] = eps;

    # Profitability.
    row["gross_margin"] = ratio(gross, revenue);
    row["operating_margin"] = ratio(operating, revenue);
    row["net_margin"] = ratio(net, revenue);
    row["fcf_margin"] = ratio(free_cash, revenue);
    row["roe"] = ratio(net, equity);
    row["roa"] = ratio(net, assets);

    # Balance sheet.
    row["total_assets"] = assets;
    row["total_liabilities"] = liabilities;
    row["equity"] = equity;
    row["cash"] = cash;
    row["debt"] = debt;
    row["debt_to_equity"] = ratio(debt, equity);
    row["current_ratio"] = ratio(current_assets, current_liabilities);

    # Cash flow.
    row["operating_cash_flow_ttm"] = cash_flow;
    row["capex_ttm"] = capex;
    row["free_cash_flow_ttm"] = free_cash;

    # Valuation. Against the whole company's size, so an ADR's ratio or a share class's price
    # cannot skew it; a loss or negative book has no ratio.
    pe = ratio(market_cap, net);
    row["pe"] = pe;
    row["ps"] = ratio(market_cap, revenue);
    row["pb"] = ratio(market_cap, equity);
    row["p_fcf"] = ratio(market_cap, free_cash);
    row["earnings_yield"] = ratio(net, market_cap);
    growth = values.get("eps_growth");
    row["peg"] = ratio(plausible("pe", pe), growth * 100.0) if growth is not None else None;
    enterprise = market_cap + (debt or 0.0) - (cash or 0.0) if market_cap is not None else None;
    row["enterprise_value"] = enterprise;
    row["ev_revenue"] = ratio(enterprise, revenue);
    row["ev_operating"] = ratio(enterprise, operating);

    # Per share. Against the row's own line, since EPS is the common share's and a line may be an ADR.
    row["revenue_ps"] = ratio(revenue, shares);
    row["book_ps"] = ratio(equity, shares);
    row["fcf_ps"] = free_cash / shares if free_cash is not None and shares else None;
    row["cash_ps"] = ratio(cash, shares);

    # Dividends.
    row["dividends_ps_ttm"] = dividends;
    row["dividend_yield"] = ratio(dividends, price) if dividends else (0.0 if values and price and "dividends_ps_ttm" not in values else None);
    row["payout_ratio"] = ratio(dividends, eps) if dividends else None;

    # Analysts and earnings.
    row["analyst_score"] = analyst.score if analyst else None;
    row["analyst_rating"] = rating_label(analyst.score) if analyst else "";
    row["analyst_count"] = float(analyst.analysts) if analyst and analyst.analysts else None;
    row["analyst_buy_share"] = analyst.buy_share if analyst else None;
    surprises = [s.surprise_pct for s in analyst.surprises if s.surprise_pct is not None] if analyst else [];
    row["eps_surprise_pct"] = surprises[-1] / 100.0 if surprises else None;
    row["earnings_last"] = dates.last_day if dates else "";
    row["earnings_next"] = dates.next_day if dates else "";
    row["earnings_last_in"] = days_until(dates.last_day, today) if dates else None;
    row["earnings_next_in"] = days_until(dates.next_day, today) if dates else None;
    row["report_period"] = company.period_end if company else "";
    for key in PLAUSIBLE {
        row[key] = plausible(key, row.get(key));
    }
    return row;
}

"""Every listed stock's row from `state`, without the funds only their filings give away."""
def build_rows(state: MarketState, today: date) -> list[dict[str, float | str | None]] {
    return [
        build_row(
            listing,
            state.quotes.get(symbol),
            state.stats.get(symbol),
            state.companies.get(listing.cik),
            state.analysts.get(symbol),
            state.earnings.get(symbol),
            today
        )
        for (symbol, listing) in state.listings.items()
        if not is_fund(listing.name, state.companies[listing.cik].sic if listing.cik in state.companies else None)
    ];
}

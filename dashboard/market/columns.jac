"""What the screener can show and filter: every field's label, how to write its value, and which
tab and filter it belongs to. Plain data and functions with no browser API, so `jac test` reads the
same table as the pages. The field names are market/rows.jac's."""
import from dashboard.ui.format { MISSING, compact, day_short, grouped, money, num, pct, signed_pct, tone }

"""One field. `format` picks the writer in `show`; `filter` is how it is narrowed: "range" for typed
bounds, "choice" for words, "days" for a date as days from today, or "" for not at all. A range's
`scale` turns what a reader types into the field's units: 1e9 for dollars typed in billions, 0.01
for a fraction typed as a percent."""
obj Field {
    has key: str,
        label: str,
        format: str = "number",
        hint: str = "",
        filter: str = "range",
        unit: str = "",
        scale: float = 1.0,
        group: str = "Other",
        presets: list[Preset] = [];
}

"""A one-click choice for a filter, with its bounds in the units a reader types."""
obj Preset {
    has label: str,
        low: float | None = None,
        high: float | None = None;
}

"""A named set of columns, the tabs over the table."""
obj ColumnSet {
    has name: str,
        columns: list[str],
        sort: str = "market_cap";
}

glob PERF_PRESETS: list[Preset] = [
    Preset(label="Above +20%", low=20.0),
    Preset(label="+5% to +20%", low=5.0, high=20.0),
    Preset(label="0 to +5%", low=0.0, high=5.0),
    Preset(label="-5% to 0", low=-5.0, high=0.0),
    Preset(label="Below -5%", high=-5.0)
];
glob GROWTH_PRESETS: list[Preset] = [
    Preset(label="Above 50%", low=50.0),
    Preset(label="Above 25%", low=25.0),
    Preset(label="Above 10%", low=10.0),
    Preset(label="Above 0%", low=0.0),
    Preset(label="Negative", high=0.0)
];
glob UPCOMING_PRESETS: list[Preset] = [
    Preset(label="Today", low=0.0, high=0.0),
    Preset(label="Next 7 days", low=0.0, high=7.0),
    Preset(label="Next 14 days", low=0.0, high=14.0),
    Preset(label="Next 30 days", low=0.0, high=30.0)
];
glob RECENT_PRESETS: list[Preset] = [
    Preset(label="Past 7 days", low=-7.0, high=0.0),
    Preset(label="Past 14 days", low=-14.0, high=0.0),
    Preset(label="Past 30 days", low=-30.0, high=0.0),
    Preset(label="Past 90 days", low=-90.0, high=0.0)
];

glob FIELDS: list[Field] = [
    Field(key="symbol", label="Symbol", format="text", filter="", group="Identity"),
    Field(key="name", label="Company", format="text", filter="", group="Identity"),
    Field(key="exchange", label="Exchange", format="text", filter="choice", group="Identity"),
    Field(key="sp500", label="Index", format="text", filter="choice", group="Identity"),
    Field(key="sector", label="Sector", format="text", filter="choice", group="Identity"),
    Field(key="industry", label="Industry", format="text", filter="", group="Identity"),

    Field(key="price", label="Price", format="money", unit="$", group="Quote", presets=[Preset(label="Under $5", high=5.0), Preset(label="$5 to $25", low=5.0, high=25.0), Preset(label="$25 to $100", low=25.0, high=100.0), Preset(label="Above $100", low=100.0)]),
    Field(key="change_pct", label="Chg %", format="signed_pct", unit="%", scale=0.01, group="Quote", presets=PERF_PRESETS),
    Field(key="change", label="Chg", format="signed_money", unit="$", group="Quote"),
    Field(key="gap_pct", label="Gap %", format="signed_pct", unit="%", scale=0.01, group="Quote", hint="This session's open against the last close"),
    Field(key="day_range_pct", label="Day range %", format="pct", unit="%", scale=0.01, group="Quote", hint="The day's high over its low"),
    Field(key="volume", label="Vol", format="compact", unit="M", scale=1e6, group="Quote"),
    Field(key="average_volume", label="Avg vol 30D", format="compact", unit="M", scale=1e6, group="Quote"),
    Field(key="rel_volume", label="Rel vol", format="number", group="Quote", hint="Today's volume over the 30-day average", presets=[Preset(label="Above 1", low=1.0), Preset(label="Above 2", low=2.0), Preset(label="Above 5", low=5.0)]),
    Field(key="dollar_volume", label="Vol x Price", format="big_money", unit="$M", scale=1e6, group="Quote"),
    Field(key="ext_price", label="Ext price", format="money", unit="$", group="Quote", hint="The latest trade outside the regular session"),
    Field(key="ext_change", label="Ext chg", format="signed_money", unit="$", group="Quote"),
    Field(key="ext_change_pct", label="Ext chg %", format="signed_pct", unit="%", scale=0.01, group="Quote", hint="The latest trade outside the regular session against its close", presets=PERF_PRESETS),

    Field(key="perf_1w", label="Perf 1W", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="perf_1m", label="Perf 1M", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="perf_3m", label="Perf 3M", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="perf_6m", label="Perf 6M", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="perf_ytd", label="Perf YTD", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="perf_1y", label="Perf 1Y", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=PERF_PRESETS),
    Field(key="volatility", label="Volatility", format="pct", unit="%", scale=0.01, group="Performance", hint="20-day realized volatility, annualized"),
    Field(key="high_52w", label="52W high", format="money", unit="$", group="Performance"),
    Field(key="low_52w", label="52W low", format="money", unit="$", group="Performance"),
    Field(key="from_high_pct", label="From 52W high", format="signed_pct", unit="%", scale=0.01, group="Performance", presets=[Preset(label="Within 5%", low=-5.0), Preset(label="Within 20%", low=-20.0), Preset(label="Down over 50%", high=-50.0)]),
    Field(key="from_low_pct", label="From 52W low", format="signed_pct", unit="%", scale=0.01, group="Performance"),

    Field(key="tech_rating", label="Tech rating", format="rating", filter="choice", group="Technicals", hint="The mean vote of six indicators, computed here from daily bars"),
    Field(key="rsi_14", label="RSI 14", format="number", group="Technicals", presets=[Preset(label="Oversold, under 30", high=30.0), Preset(label="30 to 70", low=30.0, high=70.0), Preset(label="Overbought, over 70", low=70.0)]),
    Field(key="macd_hist", label="MACD hist", format="signed", group="Technicals"),
    Field(key="sma_20_pct", label="vs. SMA 20", format="signed_pct", unit="%", scale=0.01, group="Technicals", hint="Price against its 20-day average"),
    Field(key="sma_50_pct", label="vs. SMA 50", format="signed_pct", unit="%", scale=0.01, group="Technicals", hint="Price against its 50-day average"),
    Field(key="sma_200_pct", label="vs. SMA 200", format="signed_pct", unit="%", scale=0.01, group="Technicals", hint="Price against its 200-day average"),
    Field(key="atr_pct", label="ATR %", format="pct", unit="%", scale=0.01, group="Technicals", hint="14-day average true range against price"),
    Field(key="beta", label="Beta 1Y", format="number", group="Technicals", hint="Slope of daily returns on SPY's over the last year", presets=[Preset(label="Under 0.5", high=0.5), Preset(label="0.5 to 1", low=0.5, high=1.0), Preset(label="1 to 1.5", low=1.0, high=1.5), Preset(label="Above 1.5", low=1.5)]),

    Field(key="market_cap", label="Mkt cap", format="big_money", unit="$B", scale=1e9, group="Valuation", presets=[Preset(label="Mega, $200B+", low=200.0), Preset(label="Large, $10B to $200B", low=10.0, high=200.0), Preset(label="Mid, $2B to $10B", low=2.0, high=10.0), Preset(label="Small, $300M to $2B", low=0.3, high=2.0), Preset(label="Micro, under $300M", high=0.3)]),
    Field(key="enterprise_value", label="EV", format="big_money", unit="$B", scale=1e9, group="Valuation", hint="Market cap plus debt less cash"),
    Field(key="pe", label="P/E", format="number", group="Valuation", hint="Market cap over net income for the last twelve months; a loss has none", presets=[Preset(label="Under 10", high=10.0), Preset(label="10 to 20", low=10.0, high=20.0), Preset(label="20 to 40", low=20.0, high=40.0), Preset(label="Above 40", low=40.0)]),
    Field(key="ps", label="P/S", format="number", group="Valuation", hint="Market cap over revenue"),
    Field(key="pb", label="P/B", format="number", group="Valuation", hint="Market cap over book value"),
    Field(key="p_fcf", label="P/FCF", format="number", group="Valuation", hint="Market cap over free cash flow"),
    Field(key="peg", label="PEG", format="number", group="Valuation", hint="P/E over the latest quarter's EPS growth", presets=[Preset(label="Under 1", high=1.0), Preset(label="1 to 2", low=1.0, high=2.0), Preset(label="Above 2", low=2.0)]),
    Field(key="ev_revenue", label="EV/Revenue", format="number", group="Valuation"),
    Field(key="ev_operating", label="EV/Op income", format="number", group="Valuation"),
    Field(key="earnings_yield", label="Earnings yield", format="pct", unit="%", scale=0.01, group="Valuation"),

    Field(key="dividend_yield", label="Div yield", format="pct", unit="%", scale=0.01, group="Dividends", hint="Dividends over the last twelve months against price", presets=[Preset(label="Pays any", low=0.0001), Preset(label="Above 2%", low=2.0), Preset(label="Above 4%", low=4.0), Preset(label="Above 6%", low=6.0)]),
    Field(key="dividends_ps_ttm", label="Div/share TTM", format="money", unit="$", group="Dividends"),
    Field(key="payout_ratio", label="Payout ratio", format="pct", unit="%", scale=0.01, group="Dividends", hint="Dividends over earnings per share"),

    Field(key="gross_margin", label="Gross margin", format="pct", unit="%", scale=0.01, group="Profitability"),
    Field(key="operating_margin", label="Op margin", format="pct", unit="%", scale=0.01, group="Profitability"),
    Field(key="net_margin", label="Net margin", format="pct", unit="%", scale=0.01, group="Profitability"),
    Field(key="fcf_margin", label="FCF margin", format="pct", unit="%", scale=0.01, group="Profitability"),
    Field(key="roe", label="ROE", format="pct", unit="%", scale=0.01, group="Profitability", hint="Net income over equity", presets=[Preset(label="Above 30%", low=30.0), Preset(label="Above 15%", low=15.0), Preset(label="Above 0%", low=0.0)]),
    Field(key="roa", label="ROA", format="pct", unit="%", scale=0.01, group="Profitability", hint="Net income over assets"),

    Field(key="revenue_ttm", label="Revenue TTM", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="revenue_fy", label="Revenue FY", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="revenue_growth", label="Rev growth", format="signed_pct", unit="%", scale=0.01, group="Income statement", hint="The latest quarter against the same quarter a year before", presets=GROWTH_PRESETS),
    Field(key="gross_profit_ttm", label="Gross profit", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="operating_income_ttm", label="Op income", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="net_income_ttm", label="Net income TTM", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="net_income_fy", label="Net income FY", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="net_income_growth", label="NI growth", format="signed_pct", unit="%", scale=0.01, group="Income statement", hint="The latest quarter against the same quarter a year before", presets=GROWTH_PRESETS),
    Field(key="research_ttm", label="R&D", format="big_money", unit="$B", scale=1e9, group="Income statement"),
    Field(key="eps_ttm", label="EPS TTM", format="money", unit="$", group="Per share"),
    Field(key="eps_growth", label="EPS growth", format="signed_pct", unit="%", scale=0.01, group="Per share", hint="The latest quarter against the same quarter a year before", presets=GROWTH_PRESETS),

    Field(key="total_assets", label="Assets", format="big_money", unit="$B", scale=1e9, group="Balance sheet"),
    Field(key="total_liabilities", label="Liabilities", format="big_money", unit="$B", scale=1e9, group="Balance sheet"),
    Field(key="equity", label="Equity", format="big_money", unit="$B", scale=1e9, group="Balance sheet"),
    Field(key="cash", label="Cash", format="big_money", unit="$B", scale=1e9, group="Balance sheet"),
    Field(key="debt", label="Debt", format="big_money", unit="$B", scale=1e9, group="Balance sheet"),
    Field(key="debt_to_equity", label="Debt/Equity", format="number", group="Balance sheet"),
    Field(key="current_ratio", label="Current ratio", format="number", group="Balance sheet"),

    Field(key="operating_cash_flow_ttm", label="Op cash flow", format="big_money", unit="$B", scale=1e9, group="Cash flow"),
    Field(key="capex_ttm", label="Capex", format="big_money", unit="$B", scale=1e9, group="Cash flow"),
    Field(key="free_cash_flow_ttm", label="Free cash flow", format="big_money", unit="$B", scale=1e9, group="Cash flow"),

    Field(key="revenue_ps", label="Revenue/share", format="money", unit="$", group="Per share"),
    Field(key="book_ps", label="Book/share", format="money", unit="$", group="Per share"),
    Field(key="fcf_ps", label="FCF/share", format="money", unit="$", group="Per share"),
    Field(key="cash_ps", label="Cash/share", format="money", unit="$", group="Per share"),
    Field(key="shares", label="Shares", format="compact", unit="M", scale=1e6, group="Per share"),

    Field(key="analyst_rating", label="Analyst rating", format="rating", filter="choice", group="Analysts", hint="Our score from analysts' monthly recommendations"),
    Field(key="analyst_score", label="Analyst score", format="signed", group="Analysts", hint="From -1, all strong sells, to 1, all strong buys"),
    Field(key="analyst_count", label="Analysts", format="whole", group="Analysts"),
    Field(key="analyst_buy_share", label="Rated buy", format="pct", unit="%", scale=0.01, group="Analysts", hint="Share of analysts at buy or strong buy"),
    Field(key="eps_surprise_pct", label="EPS surprise", format="signed_pct", unit="%", scale=0.01, group="Analysts", hint="How far the latest quarter beat or missed the consensus"),
    Field(key="earnings_last", label="Last earnings", format="day", filter="", group="Analysts"),
    Field(key="earnings_last_in", label="Recent earnings", format="days_ago", filter="days", group="Analysts", presets=RECENT_PRESETS),
    Field(key="earnings_next", label="Next earnings", format="day", filter="", group="Analysts"),
    Field(key="earnings_next_in", label="Upcoming earnings", format="days_ahead", filter="days", group="Analysts", presets=UPCOMING_PRESETS)
];

glob FIELD_BY_KEY: dict[str, Field] = {f.key: f for f in FIELDS};

# The filters a new screen offers, in the reference's order; "+" adds any other.
glob DEFAULT_FILTERS: list[str] = ["sp500", "exchange", "price", "change_pct", "market_cap", "pe", "eps_growth", "dividend_yield", "sector", "analyst_rating", "perf_1y", "revenue_growth", "peg", "roe", "beta", "earnings_last_in", "earnings_next_in"];

glob COLUMN_SETS: list[ColumnSet] = [
    ColumnSet(name="Overview", columns=["price", "change_pct", "volume", "rel_volume", "market_cap", "pe", "eps_ttm", "eps_growth", "dividend_yield", "sector", "analyst_rating"]),
    ColumnSet(name="Performance", columns=["price", "change_pct", "perf_1w", "perf_1m", "perf_3m", "perf_6m", "perf_ytd", "perf_1y", "volatility", "from_high_pct"], sort="perf_1y"),
    ColumnSet(name="Technicals", columns=["price", "tech_rating", "rsi_14", "macd_hist", "sma_20_pct", "sma_50_pct", "sma_200_pct", "atr_pct", "beta", "rel_volume"], sort="market_cap"),
    ColumnSet(name="Extended hours", columns=["price", "change_pct", "ext_price", "ext_change", "ext_change_pct", "gap_pct", "volume"], sort="ext_change_pct"),
    ColumnSet(name="Forecasts", columns=["price", "analyst_rating", "analyst_score", "analyst_count", "analyst_buy_share", "eps_surprise_pct", "earnings_last", "earnings_next"], sort="analyst_score"),
    ColumnSet(name="Valuation", columns=["market_cap", "enterprise_value", "pe", "ps", "pb", "p_fcf", "peg", "ev_revenue", "ev_operating", "earnings_yield"]),
    ColumnSet(name="Dividends", columns=["price", "dividend_yield", "dividends_ps_ttm", "payout_ratio", "eps_ttm", "market_cap"], sort="dividend_yield"),
    ColumnSet(name="Profitability", columns=["gross_margin", "operating_margin", "net_margin", "fcf_margin", "roe", "roa", "market_cap"]),
    ColumnSet(name="Income statement", columns=["revenue_ttm", "revenue_growth", "gross_profit_ttm", "operating_income_ttm", "net_income_ttm", "net_income_growth", "research_ttm", "eps_ttm"], sort="revenue_ttm"),
    ColumnSet(name="Balance sheet", columns=["total_assets", "total_liabilities", "equity", "cash", "debt", "debt_to_equity", "current_ratio"], sort="total_assets"),
    ColumnSet(name="Cash flow", columns=["operating_cash_flow_ttm", "capex_ttm", "free_cash_flow_ttm", "fcf_margin", "p_fcf"], sort="free_cash_flow_ttm"),
    ColumnSet(name="Per share", columns=["price", "eps_ttm", "revenue_ps", "book_ps", "fcf_ps", "cash_ps", "dividends_ps_ttm", "shares"], sort="market_cap")
];

glob RATINGS: list[str] = ["Strong buy", "Buy", "Neutral", "Sell", "Strong sell"];

"""Dollars in the units a reader expects: $3.41T, $890.2B, $12.4M."""
def big_money(x: float | None) -> str {
    if x is None {
        return MISSING;
    }
    sign = "-" if x < 0 else "";
    size = abs(x);
    if size >= 1e12 {
        return sign + "$" + grouped(size / 1e12, 2) + "T";
    }
    if size >= 1e9 {
        return sign + "$" + grouped(size / 1e9, 2) + "B";
    }
    if size >= 1e6 {
        return sign + "$" + grouped(size / 1e6, 1) + "M";
    }
    return sign + "$" + grouped(size, 0);
}

"""Days from today in words: "in 5 days", "today", "3 days ago"."""
def days_from(x: float | None) -> str {
    if x is None {
        return MISSING;
    }
    days = int(x);
    if days == 0 {
        return "Today";
    }
    if days == 1 {
        return "Tomorrow";
    }
    if days == -1 {
        return "Yesterday";
    }
    return f"In {days} days" if days > 0 else f"{0 - days} days ago";
}

"""The value of field `key` in `row`, written the way the field says."""
def show(key: str, value: any) -> str {
    field = FIELD_BY_KEY.get(key);
    format = field.format if field else "text";
    if value is None or value == "" {
        return MISSING;
    }
    if format == "money" { return money(value); }
    if format == "big_money" { return big_money(value); }
    if format == "signed_money" { return ("+" if value > 0 else "") + money(value); }
    if format == "pct" { return pct(value); }
    if format == "signed_pct" { return signed_pct(value); }
    if format == "compact" { return compact(value); }
    if format == "whole" { return num(value, 0); }
    if format == "signed" { return ("+" if value > 0 else "") + num(value, 2); }
    if format == "number" { return num(value, 2); }
    if format == "day" { return day_short(value); }
    if format == "days_ago" or format == "days_ahead" { return days_from(value); }
    return str(value);
}

"""The text color for a value: a change is green or red, and a rating follows its word."""
def tone_of(key: str, value: any) -> str {
    field = FIELD_BY_KEY.get(key);
    format = field.format if field else "text";
    if value is None or value == "" {
        return "text-faint";
    }
    if format == "signed_pct" or format == "signed_money" or format == "signed" {
        return tone(value);
    }
    if format == "rating" {
        return "text-up" if value in ["Strong buy", "Buy"] else ("text-down" if value in ["Strong sell", "Sell"] else "text-muted");
    }
    return "";
}

"""Market cap's size class, the badge beside it on a stock's page."""
def size_class(cap: float | None) -> str {
    if cap is None {
        return "";
    }
    if cap >= 2e11 { return "Mega cap"; }
    if cap >= 1e10 { return "Large cap"; }
    if cap >= 2e9 { return "Mid cap"; }
    if cap >= 3e8 { return "Small cap"; }
    return "Micro cap";
}

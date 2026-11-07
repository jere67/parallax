"""An invented market for a server started with TRADING_AGENT_DEMO=1, so the market pages work
without keys, as the rest of the demo does, and the browser tests have something stable to read.

The companies are real names with made-up numbers: every price, figure, and rating comes from a
generator seeded by the ticker, then runs through the same reductions as live data. The page's demo
banner says so. It is never written to disk, and it never mixes with live data.
"""
import random;
import from datetime { date, datetime, timedelta, timezone }
import from market.analysts { AnalystRecord, RatingPoint, Surprise }
import from market.companies { CompanyProfile, CompanyRecord, FilingLink, Period }
import from market.listings { Listing }
import from market.prices { Quote, price_stats }
import from market.sectors { COMMUNICATION, DISCRETIONARY, ENERGY, FINANCIALS, HEALTH, INDUSTRIALS, MATERIALS, REAL_ESTATE, STAPLES, TECHNOLOGY, UTILITIES }
import from market.state { EarningsDates, MarketState, summary_of }
import from models.research { Stamp }
import from research.alpaca { Bar, BarSeries }

glob DEMO_ENV: str = "TRADING_AGENT_DEMO";
glob HISTORY_START: date = date(2016, 1, 4);
glob STATS_SESSIONS: int = 320;
glob BENCHMARK: str = "SPY";

"""One invented stock: its class, its price, and its size in billions of dollars."""
obj DemoStock {
    has symbol: str,
        name: str,
        sector: str,
        industry: str,
        price: float,
        size: float,
        sp500: bool = True,
        kind: str = "common",
        exchange: str = "NYSE";
}

glob STOCKS: list[DemoStock] = [
    DemoStock(symbol="AAPL", name="Apple Inc.", sector=TECHNOLOGY, industry="Technology Hardware, Storage & Peripherals", price=232.0, size=3400.0, exchange="Nasdaq"),
    DemoStock(symbol="MSFT", name="Microsoft", sector=TECHNOLOGY, industry="Systems Software", price=431.0, size=3200.0, exchange="Nasdaq"),
    DemoStock(symbol="NVDA", name="Nvidia", sector=TECHNOLOGY, industry="Semiconductors", price=138.0, size=3300.0, exchange="Nasdaq"),
    DemoStock(symbol="AVGO", name="Broadcom", sector=TECHNOLOGY, industry="Semiconductors", price=172.0, size=800.0, exchange="Nasdaq"),
    DemoStock(symbol="AMD", name="Advanced Micro Devices", sector=TECHNOLOGY, industry="Semiconductors", price=155.0, size=250.0, exchange="Nasdaq"),
    DemoStock(symbol="INTC", name="Intel", sector=TECHNOLOGY, industry="Semiconductors", price=24.0, size=100.0, exchange="Nasdaq"),
    DemoStock(symbol="ORCL", name="Oracle Corporation", sector=TECHNOLOGY, industry="Application Software", price=170.0, size=470.0),
    DemoStock(symbol="CRM", name="Salesforce", sector=TECHNOLOGY, industry="Application Software", price=290.0, size=280.0),
    DemoStock(symbol="ADBE", name="Adobe Inc.", sector=TECHNOLOGY, industry="Application Software", price=510.0, size=225.0, exchange="Nasdaq"),
    DemoStock(symbol="CSCO", name="Cisco", sector=TECHNOLOGY, industry="Communications Equipment", price=56.0, size=225.0, exchange="Nasdaq"),
    DemoStock(symbol="HPQ", name="HP Inc.", sector=TECHNOLOGY, industry="Technology Hardware, Storage & Peripherals", price=35.0, size=33.0),
    DemoStock(symbol="DELL", name="Dell Technologies", sector=TECHNOLOGY, industry="Technology Hardware, Storage & Peripherals", price=125.0, size=88.0),
    DemoStock(symbol="GOOGL", name="Alphabet Inc.", sector=COMMUNICATION, industry="Interactive Media & Services", price=172.0, size=2100.0, exchange="Nasdaq"),
    DemoStock(symbol="META", name="Meta Platforms", sector=COMMUNICATION, industry="Interactive Media & Services", price=585.0, size=1480.0, exchange="Nasdaq"),
    DemoStock(symbol="NFLX", name="Netflix", sector=COMMUNICATION, industry="Movies & Entertainment", price=760.0, size=325.0, exchange="Nasdaq"),
    DemoStock(symbol="DIS", name="The Walt Disney Company", sector=COMMUNICATION, industry="Movies & Entertainment", price=98.0, size=178.0),
    DemoStock(symbol="T", name="AT&T", sector=COMMUNICATION, industry="Integrated Telecommunication Services", price=22.0, size=160.0),
    DemoStock(symbol="VZ", name="Verizon", sector=COMMUNICATION, industry="Integrated Telecommunication Services", price=42.0, size=177.0),
    DemoStock(symbol="AMZN", name="Amazon", sector=DISCRETIONARY, industry="Broadline Retail", price=198.0, size=2080.0, exchange="Nasdaq"),
    DemoStock(symbol="TSLA", name="Tesla, Inc.", sector=DISCRETIONARY, industry="Automobile Manufacturers", price=320.0, size=1030.0, exchange="Nasdaq"),
    DemoStock(symbol="HD", name="The Home Depot", sector=DISCRETIONARY, industry="Home Improvement Retail", price=405.0, size=400.0),
    DemoStock(symbol="MCD", name="McDonald's", sector=DISCRETIONARY, industry="Restaurants", price=295.0, size=212.0),
    DemoStock(symbol="NKE", name="Nike, Inc.", sector=DISCRETIONARY, industry="Footwear", price=78.0, size=116.0),
    DemoStock(symbol="F", name="Ford Motor Company", sector=DISCRETIONARY, industry="Automobile Manufacturers", price=11.0, size=44.0),
    DemoStock(symbol="WMT", name="Walmart", sector=STAPLES, industry="Consumer Staples Merchandise Retail", price=84.0, size=675.0, exchange="Nasdaq"),
    DemoStock(symbol="COST", name="Costco", sector=STAPLES, industry="Consumer Staples Merchandise Retail", price=920.0, size=408.0, exchange="Nasdaq"),
    DemoStock(symbol="PG", name="Procter & Gamble", sector=STAPLES, industry="Personal Care Products", price=168.0, size=396.0),
    DemoStock(symbol="KO", name="The Coca-Cola Company", sector=STAPLES, industry="Soft Drinks & Non-alcoholic Beverages", price=63.0, size=271.0),
    DemoStock(symbol="PEP", name="PepsiCo", sector=STAPLES, industry="Soft Drinks & Non-alcoholic Beverages", price=160.0, size=220.0, exchange="Nasdaq"),
    DemoStock(symbol="XOM", name="ExxonMobil", sector=ENERGY, industry="Integrated Oil & Gas", price=118.0, size=520.0),
    DemoStock(symbol="CVX", name="Chevron Corporation", sector=ENERGY, industry="Integrated Oil & Gas", price=157.0, size=280.0),
    DemoStock(symbol="COP", name="ConocoPhillips", sector=ENERGY, industry="Oil & Gas Exploration & Production", price=110.0, size=127.0),
    DemoStock(symbol="SLB", name="Schlumberger", sector=ENERGY, industry="Oil & Gas Equipment & Services", price=42.0, size=59.0),
    DemoStock(symbol="JPM", name="JPMorgan Chase", sector=FINANCIALS, industry="Diversified Banks", price=240.0, size=680.0),
    DemoStock(symbol="BAC", name="Bank of America", sector=FINANCIALS, industry="Diversified Banks", price=44.0, size=340.0),
    DemoStock(symbol="WFC", name="Wells Fargo", sector=FINANCIALS, industry="Diversified Banks", price=70.0, size=235.0),
    DemoStock(symbol="GS", name="Goldman Sachs", sector=FINANCIALS, industry="Investment Banking & Brokerage", price=575.0, size=180.0),
    DemoStock(symbol="MS", name="Morgan Stanley", sector=FINANCIALS, industry="Investment Banking & Brokerage", price=128.0, size=206.0),
    DemoStock(symbol="V", name="Visa Inc.", sector=FINANCIALS, industry="Transaction & Payment Processing Services", price=308.0, size=590.0),
    DemoStock(symbol="MA", name="Mastercard", sector=FINANCIALS, industry="Transaction & Payment Processing Services", price=520.0, size=475.0),
    DemoStock(symbol="BRK.B", name="Berkshire Hathaway", sector=FINANCIALS, industry="Multi-Sector Holdings", price=470.0, size=1010.0),
    DemoStock(symbol="LLY", name="Eli Lilly and Company", sector=HEALTH, industry="Pharmaceuticals", price=830.0, size=790.0),
    DemoStock(symbol="JNJ", name="Johnson & Johnson", sector=HEALTH, industry="Pharmaceuticals", price=155.0, size=373.0),
    DemoStock(symbol="MRK", name="Merck & Co.", sector=HEALTH, industry="Pharmaceuticals", price=100.0, size=253.0),
    DemoStock(symbol="PFE", name="Pfizer", sector=HEALTH, industry="Pharmaceuticals", price=27.0, size=153.0),
    DemoStock(symbol="UNH", name="UnitedHealth Group", sector=HEALTH, industry="Managed Health Care", price=590.0, size=545.0),
    DemoStock(symbol="ABT", name="Abbott Laboratories", sector=HEALTH, industry="Health Care Equipment", price=115.0, size=200.0),
    DemoStock(symbol="CAT", name="Caterpillar Inc.", sector=INDUSTRIALS, industry="Construction Machinery & Heavy Transportation Equipment", price=380.0, size=184.0),
    DemoStock(symbol="BA", name="Boeing", sector=INDUSTRIALS, industry="Aerospace & Defense", price=155.0, size=97.0),
    DemoStock(symbol="GE", name="GE Aerospace", sector=INDUSTRIALS, industry="Aerospace & Defense", price=172.0, size=187.0),
    DemoStock(symbol="HON", name="Honeywell", sector=INDUSTRIALS, industry="Industrial Conglomerates", price=210.0, size=137.0, exchange="Nasdaq"),
    DemoStock(symbol="UPS", name="United Parcel Service", sector=INDUSTRIALS, industry="Air Freight & Logistics", price=135.0, size=115.0),
    DemoStock(symbol="LIN", name="Linde plc", sector=MATERIALS, industry="Industrial Gases", price=460.0, size=220.0, exchange="Nasdaq"),
    DemoStock(symbol="SHW", name="Sherwin-Williams", sector=MATERIALS, industry="Specialty Chemicals", price=370.0, size=93.0),
    DemoStock(symbol="FCX", name="Freeport-McMoRan", sector=MATERIALS, industry="Copper", price=45.0, size=65.0),
    DemoStock(symbol="NEE", name="NextEra Energy", sector=UTILITIES, industry="Multi-Utilities", price=79.0, size=163.0),
    DemoStock(symbol="DUK", name="Duke Energy", sector=UTILITIES, industry="Electric Utilities", price=113.0, size=87.0),
    DemoStock(symbol="SO", name="Southern Company", sector=UTILITIES, industry="Electric Utilities", price=90.0, size=98.0),
    DemoStock(symbol="PLD", name="Prologis", sector=REAL_ESTATE, industry="Industrial REITs", price=108.0, size=100.0),
    DemoStock(symbol="AMT", name="American Tower", sector=REAL_ESTATE, industry="Telecom Tower REITs", price=198.0, size=92.0),
    DemoStock(symbol="O", name="Realty Income", sector=REAL_ESTATE, industry="Retail REITs", price=56.0, size=49.0),
    DemoStock(symbol="HOOD", name="Robinhood Markets", sector=FINANCIALS, industry="Security brokers, dealers & flotation companies", price=38.0, size=33.0, sp500=False, exchange="Nasdaq"),
    DemoStock(symbol="RBLX", name="Roblox Corporation", sector=COMMUNICATION, industry="Services-prepackaged software", price=52.0, size=33.0, sp500=False),
    DemoStock(symbol="SNOW", name="Snowflake Inc.", sector=TECHNOLOGY, industry="Services-prepackaged software", price=128.0, size=42.0, sp500=False),
    DemoStock(symbol="ETSY", name="Etsy, Inc.", sector=DISCRETIONARY, industry="Retail-catalog & mail-order houses", price=52.0, size=6.0, sp500=False, exchange="Nasdaq"),
    DemoStock(symbol="CROX", name="Crocs, Inc.", sector=DISCRETIONARY, industry="Rubber & plastics footwear", price=108.0, size=6.3, sp500=False, exchange="Nasdaq"),
    DemoStock(symbol="SONO", name="Sonos, Inc.", sector=DISCRETIONARY, industry="Household audio & video equipment", price=13.0, size=1.6, sp500=False, exchange="Nasdaq"),
    DemoStock(symbol="TSM", name="Taiwan Semiconductor Manufacturing", sector=TECHNOLOGY, industry="Semiconductors & related devices", price=190.0, size=985.0, sp500=False, kind="adr"),
    DemoStock(symbol="SAP", name="SAP SE", sector=TECHNOLOGY, industry="Services-prepackaged software", price=235.0, size=275.0, sp500=False, kind="adr"),
    DemoStock(symbol="BABA", name="Alibaba Group Holding", sector=DISCRETIONARY, industry="Retail-catalog & mail-order houses", price=87.0, size=210.0, sp500=False, kind="adr")
];

"""Weekdays from `start` through `end`, the invented market's sessions."""
def demo_sessions(start: date, end: date) -> list[str] {
    days: list[str] = [];
    day = start;
    while day <= end {
        if day.weekday() < 5 {
            days.append(day.isoformat());
        }
        day += timedelta(days=1);
    }
    return days;
}

"""The nearest working day on or after `day`, since a company reports on one."""
def weekday_of(day: date) -> date {
    return day + timedelta(days=7 - day.weekday() if day.weekday() >= 5 else 0);
}

"""A random walk through `days`, ending at `price`, seeded by the ticker so it never changes."""
def demo_bars(symbol: str, price: float, days: list[str], volume: float) -> list[Bar] {
    rng = random.Random(f"bars:{symbol}");
    closes = [price];
    drift = rng.uniform(0.0, 0.0005);
    wander = rng.uniform(0.008, 0.02);
    # Every stock moves partly with one invented market, so beta means something here too.
    beta = 1.0 if symbol == BENCHMARK else rng.uniform(0.5, 1.6);
    for day in reversed(days[1:]) {
        market = random.Random(f"market:{day}").gauss(0.0003, 0.009);
        alone = 0.0 if symbol == BENCHMARK else rng.gauss(drift, wander);
        closes.append(max(0.5, closes[-1] / (1.0 + beta * market + alone)));
    }
    closes.reverse();
    bars: list[Bar] = [];
    for (i, day) in enumerate(days) {
        close = closes[i];
        before = closes[i - 1] if i > 0 else close;
        spread = close * rng.uniform(0.003, 0.018);
        bars.append(Bar(
            day=day,
            open=before,
            high=max(before, close) + spread,
            low=max(0.01, min(before, close) - spread),
            close=close,
            volume=volume * rng.uniform(0.6, 1.5),
            trades=0,
            vwap=close
        ));
    }
    return bars;
}

def demo_stamp(day: str) -> Stamp {
    return Stamp(source="demo", dataset="demo", source_url="", fetched_at=f"{day}T21:00:00+00:00", published_at=day);
}

"""The stock's share volume, which falls with its size and price."""
def demo_volume(stock: DemoStock) -> float {
    return max(2.0e5, stock.size * 1e9 * 0.004 / stock.price);
}

"""Five sessions of five-minute bars ending at the stock's price."""
def demo_intraday(symbol: str, today: date) -> list[Bar] {
    stock = stock_of(symbol);
    if stock is None {
        return [];
    }
    rng = random.Random(f"intraday:{symbol}");
    sessions = demo_sessions(today - timedelta(days=9), today - timedelta(days=1))[-5:];
    stamps: list[str] = [];
    for day in sessions {
        for minute in range(0, 390, 5) {
            start = datetime.fromisoformat(f"{day}T14:30:00+00:00") + timedelta(minutes=minute);
            stamps.append(start.isoformat());
        }
    }
    close = stock.price;
    closes: list[float] = [];
    for _ in stamps {
        closes.append(close);
        close = close / (1.0 + rng.gauss(0.00002, 0.0012));
    }
    closes.reverse();
    return [
        Bar(day=stamp, open=closes[i - 1] if i else closes[i], high=closes[i] * 1.001, low=closes[i] * 0.999, close=closes[i], volume=demo_volume(stock) / 78.0, trades=0, vwap=closes[i])
        for (i, stamp) in enumerate(stamps)
    ];
}

def stock_of(symbol: str) -> DemoStock | None {
    for stock in STOCKS {
        if stock.symbol == symbol {
            return stock;
        }
    }
    return None;
}

"""Daily bars back to 2016, for the price chart."""
def demo_history(symbol: str, today: date) -> list[Bar] {
    stock = stock_of(symbol);
    if stock is None {
        return [];
    }
    return demo_bars(symbol, stock.price, demo_sessions(HISTORY_START, today - timedelta(days=1)), demo_volume(stock));
}

"""The company's invented figures: a margin and growth picked by ticker, scaled to its size."""
def demo_company(stock: DemoStock, cik: str, today: date) -> CompanyRecord {
    rng = random.Random(f"company:{stock.symbol}");
    revenue = stock.size * 1e9 / rng.uniform(1.5, 9.0);
    net_margin = rng.uniform(-0.06, 0.3);
    gross_margin = max(net_margin + 0.1, rng.uniform(0.2, 0.78));
    operating_margin = net_margin + rng.uniform(0.02, 0.08);
    growth = rng.uniform(-0.08, 0.3);
    shares = stock.size * 1e9 / stock.price;
    equity = stock.size * 1e9 / rng.uniform(1.5, 14.0);
    debt = revenue * rng.uniform(0.05, 1.2);
    cash = revenue * rng.uniform(0.05, 0.5);
    pays_dividend = rng.random() < 0.55 and net_margin > 0.04;
    eps_now = revenue * net_margin / shares;
    annual: list[Period] = [];
    for years_back in range(5, -1, -1) {
        year = today.year - 1 - years_back;
        factor = (1.0 + growth) ** (0 - years_back);
        wiggle = rng.uniform(0.9, 1.1);
        annual.append(Period(
            end=f"{year}-12-31",
            label=f"FY{year}",
            values={
                "revenue": revenue * factor,
                "gross_profit": revenue * factor * gross_margin,
                "operating_income": revenue * factor * operating_margin * wiggle,
                "net_income": revenue * factor * net_margin * wiggle,
                "operating_cash_flow": revenue * factor * (net_margin + 0.08),
                "capital_expenditure": revenue * factor * 0.04,
                "free_cash_flow": revenue * factor * (net_margin + 0.04),
                "debt": debt * rng.uniform(0.8, 1.2),
                "cash": cash * rng.uniform(0.7, 1.3)
            }
        ));
    }
    quarterly: list[Period] = [];
    for quarters_back in range(7, -1, -1) {
        months = today.month - 3 * quarters_back - 2;
        year = today.year + (months - 1) // 12;
        month = (months - 1) % 12 + 1;
        end = date(year, month, 28);
        factor = (1.0 + growth) ** (0.0 - quarters_back / 4.0) * rng.uniform(0.94, 1.06);
        quarterly.append(Period(
            end=end.isoformat(),
            label=f"Q{(month - 1) // 3 + 1} {year}",
            values={"revenue": revenue / 4.0 * factor, "net_income": revenue / 4.0 * factor * net_margin, "gross_profit": revenue / 4.0 * factor * gross_margin}
        ));
    }
    assets = equity + debt + revenue * 0.3;
    values: dict[str, float] = {
        "revenue_ttm": revenue,
        "gross_profit_ttm": revenue * gross_margin,
        "operating_income_ttm": revenue * operating_margin,
        "net_income_ttm": revenue * net_margin,
        "research_ttm": revenue * rng.uniform(0.0, 0.14),
        "operating_cash_flow_ttm": revenue * (net_margin + 0.08),
        "capital_expenditure_ttm": revenue * 0.04,
        "free_cash_flow_ttm": revenue * (net_margin + 0.04),
        "revenue_growth": growth,
        "net_income_growth": growth * rng.uniform(0.6, 1.8),
        "eps_ttm": eps_now,
        "eps_growth": growth * rng.uniform(0.6, 1.8),
        "total_assets": assets,
        "total_liabilities": assets - equity,
        "stockholders_equity": equity,
        "cash": cash,
        "debt": debt,
        "current_assets": cash + revenue * 0.25,
        "current_liabilities": revenue * rng.uniform(0.15, 0.4),
        "shares": shares,
        "revenue_fy": annual[-1].values["revenue"],
        "net_income_fy": annual[-1].values["net_income"]
    };
    if pays_dividend {
        values["dividends_ps_ttm"] = stock.price * rng.uniform(0.004, 0.045);
    }
    newest = quarterly[-1].end;
    return CompanyRecord(
        cik=cik,
        checked=today.isoformat(),
        report_filed=newest,
        facts_filed=newest,
        period_end=newest,
        profile=CompanyProfile(
            name=stock.name,
            sic=0,
            sic_description=stock.industry,
            city="Sample City",
            region="Demo",
            incorporated="DE",
            fiscal_year_end="1231",
            ein="000000000",
            filer_category="Large accelerated filer"
        ),
        values=values,
        annual=annual,
        quarterly=quarterly,
        filings=[
            FilingLink(form="10-Q", filed=newest, report_date=newest, url="https://www.sec.gov/edgar/search/"),
            FilingLink(form="8-K", filed=newest, report_date=newest, url="https://www.sec.gov/edgar/search/"),
            FilingLink(form="10-K", filed=annual[-1].end, report_date=annual[-1].end, url="https://www.sec.gov/edgar/search/")
        ]
    );
}

"""The whole invented market as of `today`."""
def demo_state(today: date) -> MarketState {
    state = MarketState(demo=True, loaded=True);
    start = today - timedelta(days=STATS_SESSIONS * 7 // 5);
    days = demo_sessions(start, today - timedelta(days=1));
    last = days[-1];
    spy_bars = demo_bars(BENCHMARK, 575.0, days, 5e7);
    spy = BarSeries(symbol=BENCHMARK, bars=spy_bars, stamp=demo_stamp(last));
    for (i, stock) in enumerate(STOCKS) {
        cik = str(9000000000 + i);
        rng = random.Random(f"quote:{stock.symbol}");
        volume = demo_volume(stock);
        bars = demo_bars(stock.symbol, stock.price, days, volume);
        state.listings[stock.symbol] = Listing(
            symbol=stock.symbol,
            name=stock.name,
            cik=cik,
            exchange=stock.exchange,
            kind=stock.kind,
            sp500=stock.sp500,
            sector=stock.sector,
            industry=stock.industry
        );
        state.stats[stock.symbol] = price_stats(BarSeries(symbol=stock.symbol, bars=bars, stamp=demo_stamp(last)), spy);
        final = bars[-1];
        prev_close = bars[-2].close;
        state.quotes[stock.symbol] = Quote(
            symbol=stock.symbol,
            day=last,
            price=final.close,
            prev_close=prev_close,
            open=final.open,
            high=final.high,
            low=final.low,
            volume=final.volume * rng.uniform(0.7, 1.6),
            ext_price=final.close * rng.uniform(0.992, 1.008) if rng.random() < 0.4 else None,
            trade_at=f"{last}T22:30:00+00:00"
        );
        record = demo_company(stock, cik, today);
        state.save_company(record);
        state.companies[cik] = summary_of(record);
        score = rng.uniform(-0.3, 0.9);
        state.analysts[stock.symbol] = AnalystRecord(
            symbol=stock.symbol,
            checked=today.isoformat(),
            implied_shares=stock.size * 1e9 / stock.price,
            ipo="1995-06-15",
            website="",
            score=score,
            analysts=rng.randint(6, 48),
            buy_share=min(1.0, max(0.0, 0.5 + score / 2.0)),
            trend=[
                RatingPoint(
                    period=(date(today.year, today.month, 1) - timedelta(days=30 * back)).replace(day=1).isoformat(),
                    score=min(1.0, max(-1.0, score + rng.uniform(-0.15, 0.15))),
                    analysts=rng.randint(6, 48)
                )
                for back in range(5, -1, -1)
            ],
            surprises=[
                Surprise(
                    period=(today - timedelta(days=91 * back)).isoformat(),
                    surprise_pct=rng.uniform(-6.0, 12.0)
                )
                for back in range(4, 0, -1)
            ]
        );
        state.earnings[stock.symbol] = EarningsDates(
            last_day=weekday_of(today - timedelta(days=rng.randint(3, 60))).isoformat(),
            next_day=weekday_of(today + timedelta(days=rng.randint(1, 60))).isoformat(),
            next_hour=rng.choice(["bmo", "amc"])
        );
    }
    state.meta["quotes_at"] = datetime.combine(today, datetime.min.time(), timezone.utc).isoformat();
    state.meta["stats_day"] = last;
    state.meta["sessions"] = ",".join(days[-10:]);
    state.changed();
    return state;
}

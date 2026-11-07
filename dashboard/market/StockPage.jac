"""One stock's page: its quote and price chart, how it compares with its peers, its key figures, who
it is, its financials, what indicators and analysts say, its seasons, headlines, and filings. Only
sources this project can show are here; a section with nothing to back it is left out rather than
filled with something made up."""
import from "@jac/runtime" { Link, useNavigate, useParams }
import from "lucide-react" { ChevronRight, ExternalLink, Star }
import from react { useEffect }
import from dashboard.market.PriceChart { CompareLine, MAX_COMPARE, PriceChart }
import from dashboard.market.charts { BarSeriesSpec, Gauge, PeriodBars, ProfitSteps, RatingBars, SeasonTable, SurpriseBars }
import from dashboard.market.columns { big_money, show, size_class, tone_of }
import from dashboard.market.saved { toggle_watch, watched }
import from dashboard.ui.format { MISSING, compact, day_long, day_short, money, num, pct, signed, signed_money, signed_pct, stamp_et, title, tone }
import from dashboard.ui.parts { ActionBadge, Delta, Empty, ErrorBox, Field, Loading, Overline, PILL_BASE, Panel, ROW, SEGMENTS, Stat, TD, TD_NUM, TH, TH_NUM, TONE_ACCENT, TONE_QUIET }
import from market.api { get_stock, get_stock_about, get_stock_history }
import from models.market {
    BarView as BarData,
    HistoryView as HistoryData,
    PeerView as PeerData,
    PeriodView as PeriodData,
    SignalView as SignalData,
    StockAboutView as AboutData,
    StockView as StockData
}

glob TABS: list[tuple[str, str]] = [("", "Overview"), ("financials", "Financials"), ("technicals", "Technicals"), ("forecasts", "Forecasts"), ("seasonals", "Seasonals"), ("news", "News"), ("filings", "Filings")];
glob BUSY_RETRY_MS: int = 8000;
glob REVENUE_SERIES: list[BarSeriesSpec] = [
    BarSeriesSpec(key="revenue", label="Revenue", color="var(--compare-2)"),
    BarSeriesSpec(key="net_income", label="Net income", color="var(--compare-1)")
];
glob DEBT_SERIES: list[BarSeriesSpec] = [
    BarSeriesSpec(key="debt", label="Debt", color="var(--compare-3)"),
    BarSeriesSpec(key="free_cash_flow", label="Free cash flow", color="var(--compare-2)"),
    BarSeriesSpec(key="cash", label="Cash", color="var(--compare-1)")
];

def value_of(stock: StockData, key_: str) -> float | None {
    found: any = stock.values.get(key_);
    return found if typeof(found) == "number" else None;
}

def word_of(stock: StockData, key_: str) -> str {
    found: any = stock.values.get(key_);
    return found if typeof(found) == "string" else "";
}

"""The company's first letter on a quiet square, where a logo would go."""
def Monogram(symbol: str, large: bool = False) -> JsxElement {
    <span className={"grid shrink-0 place-items-center rounded-md bg-panel-2 font-medium text-muted " + ("size-12 text-[18px]" if large else "size-7 text-[12px]")} aria-hidden="true">{symbol[0:1]}</span>
}

def phase_text(phase: str) -> str {
    if phase == "open" {
        return "Market open";
    }
    if phase == "pre-market" {
        return "Pre-market";
    }
    return "After hours" if phase == "after-hours" else "Market closed";
}

"""What the price is: during a session a delayed quote, otherwise the last close."""
def quote_note(stock: StockData) -> str {
    phase = phase_text(stock.market_phase);
    if stock.market_phase == "closed" {
        return phase + " · close of " + day_short(word_of(stock, "quote_day"));
    }
    return phase + " · delayed about 15 minutes";
}

def Breadcrumbs(stock: StockData) -> JsxElement {
    sector = word_of(stock, "sector");
    <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-1 text-[12px] text-muted">
        <Link to="/screener" className="hover:text-text">Screener</Link>
        {if sector {
            <ChevronRight size={12} className="text-faint" aria-hidden="true"/>
            <Link to={"/screener?f=sector~" + encodeURIComponent(sector)} className="hover:text-text">{sector}</Link>
        }}
        <ChevronRight size={12} className="text-faint" aria-hidden="true"/>
        <span className="text-text">{stock.symbol}</span>
    </nav>
}

def Header(stock: StockData, starred: bool, star: Callable[[], None]) -> JsxElement {
    price = value_of(stock, "price");
    change = value_of(stock, "change");
    change_pct = value_of(stock, "change_pct");
    ext = value_of(stock, "ext_price");
    ext_pct = value_of(stock, "ext_change_pct");
    <header className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-3">
                <Monogram symbol={stock.symbol} large={True}/>
                <div className="min-w-0">
                    <h1 className="display truncate text-[30px] leading-9 text-text">{stock.name}</h1>
                    <p className="flex flex-wrap items-center gap-x-1.5 text-[12px] text-muted">
                        <span className="font-semibold text-text">{stock.symbol}</span>
                        <span>{word_of(stock, "exchange")}</span>
                        {if word_of(stock, "sp500") {
                            <span className={PILL_BASE + " " + TONE_QUIET}>S&P 500</span>
                        }}
                        {if word_of(stock, "kind") == "adr" {
                            <span className={PILL_BASE + " " + TONE_QUIET} title="American depositary receipt">ADR</span>
                        }}
                    </p>
                </div>
                <button
                    type="button"
                    aria-pressed={starred}
                    aria-label={"Remove " + stock.symbol + " from the watchlist" if starred else "Add " + stock.symbol + " to the watchlist"}
                    className={"press grid size-8 shrink-0 place-items-center rounded-md hover:bg-hover " + ("text-accent" if starred else "text-faint hover:text-text")}
                    onClick={lambda { star(); }}
                >
                    <Star size={16} strokeWidth={1.75} fill={"currentColor" if starred else "none"} aria-hidden="true"/>
                </button>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-x-2.5 gap-y-1">
                <span className="display text-[40px] leading-[44px] text-text">{money(price)}</span>
                <span className="text-[11px] text-muted">USD</span>
                <Delta text={signed_pct(change_pct)} value={change_pct}/>
                <span className={"num text-[13px] font-medium " + tone(change)}>{signed_money(change)}</span>
            </div>
            <p className="num mt-1 text-[12px] text-muted">
                {quote_note(stock)}
                {if ext is not None {
                    <span className="ml-2 text-text">{"Extended hours " + money(ext)}<span className={"ml-1 " + tone(ext_pct)}>{signed_pct(ext_pct)}</span></span>
                }}
            </p>
        </div>
        {if stock.committee.run_day or stock.committee.held {
            <div className="rounded-md border border-line bg-panel px-3 py-2.5 lg:max-w-xs">
                <Overline>The committee</Overline>
                <div className="mt-1 flex flex-wrap items-center gap-2 text-[13px] text-text">
                    {if stock.committee.action {
                        <ActionBadge action={stock.committee.action}/>
                    }}
                    {if stock.committee.held {
                        <span>{"Holds " + num(float(stock.committee.held_qty or 0), 0) + " shares"}</span>
                    }}
                    {if stock.committee.trail {
                        <Link to={stock.committee.trail} className="text-accent hover:underline">{"Decision of " + day_short(stock.committee.run_day)}</Link>
                    }}
                </div>
            </div>
        }}
    </header>
}

def Tabs(symbol: str, active: str) -> JsxElement {
    <div className="scroll-x flex gap-4 border-b border-line" role="tablist" aria-label="Stock sections">
        {for (slug, name) in TABS {
            <Link
                key={name}
                to={"/stocks/" + symbol + ("/" + slug if slug else "")}
                role="tab"
                aria-selected={active == slug}
                className={"flex h-9 shrink-0 items-center whitespace-nowrap border-b-2 text-[13px] font-medium transition-colors duration-150 " + ("border-accent text-text" if active == slug else "border-transparent text-muted hover:text-text")}
            >{name}</Link>
        }}
    </div>
}

"""A row of comparable stocks, each a link with a button to draw it on the chart."""
def PeerCards(peers: list[PeerData], compared: list[str], toggle: Callable[[str], None]) -> JsxElement {
    <div className="scroll-x flex gap-2 pb-1">
        {for peer in peers {
            <div key={peer.symbol} className={"w-44 shrink-0 rounded-md border bg-panel p-3 " + ("border-accent/50" if peer.symbol in compared else "border-line")}>
                <div className="flex items-start justify-between gap-2">
                    <Link to={"/stocks/" + peer.symbol} className="group/peer min-w-0">
                        <div className="text-[13px] font-semibold text-text group-hover/peer:text-accent">{peer.symbol}</div>
                        <div className="truncate text-[11px] text-muted">{peer.name}</div>
                    </Link>
                    <button
                        type="button"
                        aria-pressed={peer.symbol in compared}
                        disabled={len(compared) >= MAX_COMPARE and peer.symbol not in compared}
                        title={"Remove from the chart" if peer.symbol in compared else "Compare on the chart"}
                        aria-label={("Remove " + peer.symbol + " from the chart") if peer.symbol in compared else ("Compare " + peer.symbol + " on the chart")}
                        className={"press h-6 shrink-0 rounded border px-1.5 text-[11px] font-medium disabled:opacity-40 " + ("border-accent/40 bg-accent/15 text-accent" if peer.symbol in compared else "border-line text-muted hover:text-text")}
                        onClick={lambda { toggle(peer.symbol); }}
                    >{"On" if peer.symbol in compared else "Add"}</button>
                </div>
                <div className="num mt-2 flex items-baseline justify-between gap-2 text-[12px]">
                    <span className="text-text">{money(peer.price)}</span>
                    <span className={tone(peer.change_pct)}>{signed_pct(peer.change_pct)}</span>
                </div>
                <div className="num mt-0.5 flex items-baseline justify-between gap-2 text-[11px] text-muted">
                    <span>{big_money(peer.market_cap)}</span>
                    <span>{"P/E " + num(peer.pe)}</span>
                </div>
            </div>
        }}
    </div>
}

"""One figure in a hairline grid of figures."""
def Figure(label: str, value: str, sub: any = None, hint: str = "", value_tone: str = "text-text") -> JsxElement {
    <div className="min-w-0 bg-panel px-4 py-3.5">
        <Stat label={label} value={value} sub={sub} hint={hint} tone={value_tone}/>
    </div>
}

"""Whether SEC's data holds reported figures for this company."""
def has_figures(stock: StockData) -> bool {
    return len(stock.annual) + len(stock.quarterly) > 0 or value_of(stock, "net_income_ttm") is not None or value_of(stock, "total_assets") is not None;
}

def KeyStats(stock: StockData) -> JsxElement {
    cap = value_of(stock, "market_cap");
    badge = size_class(cap);
    if not has_figures(stock) {
        return <div className="grid grid-cols-2 gap-px bg-line sm:grid-cols-4">
            <Figure label="Market cap" value={big_money(cap)} sub={badge}/>
            <Figure label="Shares" value={compact(value_of(stock, "shares"))} hint="Shares outstanding, in this listing's units"/>
            <Figure label="Beta 1Y" value={num(value_of(stock, "beta"))} hint="Slope of daily returns on SPY's over the last year"/>
            <Figure label="Volume 30D" value={compact(value_of(stock, "average_volume"))} hint="Average shares traded a day over the last 30 sessions"/>
        </div>;
    }
    <div className="grid grid-cols-2 gap-px bg-line sm:grid-cols-4">
        <Figure label="Market cap" value={big_money(cap)} sub={badge}/>
        <Figure label="Dividend yield" value={pct(value_of(stock, "dividend_yield"))} hint="Dividends over the last twelve months against price"/>
        <Figure label="P/E TTM" value={num(value_of(stock, "pe"))} hint="Market cap over net income for the last twelve months; a loss has none"/>
        <Figure label="EPS TTM" value={money(value_of(stock, "eps_ttm"))} sub={signed_pct(value_of(stock, "eps_growth")) + " last quarter YoY" if value_of(stock, "eps_growth") is not None else ""}/>
        <Figure label="Net income FY" value={big_money(value_of(stock, "net_income_fy"))}/>
        <Figure label="Revenue FY" value={big_money(value_of(stock, "revenue_fy"))} sub={signed_pct(value_of(stock, "revenue_growth")) + " last quarter YoY" if value_of(stock, "revenue_growth") is not None else ""}/>
        <Figure label="Shares" value={compact(value_of(stock, "shares"))} hint="Shares outstanding, in this listing's units"/>
        <Figure label="Beta 1Y" value={num(value_of(stock, "beta"))} hint="Slope of daily returns on SPY's over the last year"/>
    </div>
}

"""Today's trading against its usual: the session's figures, and where the price sits in its year."""
def KeyFacts(stock: StockData) -> JsxElement {
    price = value_of(stock, "price");
    low = value_of(stock, "low_52w");
    high = value_of(stock, "high_52w");
    place = (price - low) / (high - low) * 100.0 if price is not None and low is not None and high is not None and high > low else None;
    <div className="grid gap-5 md:grid-cols-2">
        <div>
            <Field label="Volume">{compact(value_of(stock, "volume"))}</Field>
            <Field label="Average volume, 30 days">{compact(value_of(stock, "average_volume"))}</Field>
            <Field label="Relative volume">{num(value_of(stock, "rel_volume"))}</Field>
            <Field label="Gap at the open"><span className={tone(value_of(stock, "gap_pct"))}>{signed_pct(value_of(stock, "gap_pct"))}</span></Field>
        </div>
        <div>
            <Overline>52-week range</Overline>
            <div className="relative mt-3 h-1.5 rounded-full bg-panel-2">
                {if place is not None {
                    <span className="absolute top-1/2 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-panel bg-accent" style={{"left": str(place) + "%"}}></span>
                }}
            </div>
            <div className="num mt-2 flex justify-between text-[12px] text-muted">
                <span>{money(low)}</span>
                <span>{money(high)}</span>
            </div>
            <Field label="From the high"><span className={tone(value_of(stock, "from_high_pct"))}>{signed_pct(value_of(stock, "from_high_pct"))}</span></Field>
            <Field label="Volatility, annualized">{pct(value_of(stock, "volatility"))}</Field>
        </div>
    </div>
}

def Earnings(stock: StockData) -> JsxElement {
    next_day = word_of(stock, "earnings_next");
    last_day = word_of(stock, "earnings_last");
    <div>
        <div className="grid grid-cols-2 gap-3">
            <div>
                <Overline>Next report</Overline>
                <div className="num mt-1 text-[14px] text-text">{day_long(next_day) if next_day else MISSING}</div>
            </div>
            <div>
                <Overline>Last report</Overline>
                <div className="num mt-1 text-[14px] text-text">{day_long(last_day) if last_day else MISSING}</div>
            </div>
        </div>
        <div className="mt-4">
            <Overline className="mb-2">EPS against the consensus</Overline>
            <SurpriseBars surprises={stock.surprises}/>
        </div>
    </div>
}

def CompanyInfo(stock: StockData, about: AboutData | None) -> JsxElement {
    has expanded: bool = False;

    profile = stock.profile;
    description = about.description if about is not None else "";
    long = len(description) > 280;
    shown = description[0:280] + "..." if long and not expanded else description;
    <div>
        {if description {
            <p className="text-[13px] leading-5 text-text">
                {shown}
                {if long {
                    <button type="button" className="ml-1 text-accent hover:underline" onClick={lambda { expanded = not expanded; }}>{"Show less" if expanded else "Show more"}</button>
                }}
            </p>
        }}
        {if about is not None and about.description_url {
            <p className="mt-1 text-[11px] text-faint">
                <a href={about.description_url} target="_blank" rel="noopener noreferrer" className="hover:text-text">From Wikipedia</a>
                {" under CC BY-SA"}
            </p>
        }}
        <dl className="mt-3 grid gap-x-8 sm:grid-cols-2">
            <Field label="Sector">{word_of(stock, "sector") or MISSING}</Field>
            <Field label="Industry">{word_of(stock, "industry") or MISSING}</Field>
            <Field label="Headquarters">{profile.headquarters or MISSING}</Field>
            <Field label="Incorporated">{profile.incorporated or MISSING}</Field>
            <Field label="Website">
                {if profile.website {
                    <a href={profile.website} target="_blank" rel="noopener noreferrer" className="text-accent hover:underline">{profile.website.replace("https://", "").replace("http://", "").rstrip("/")}</a>
                } else {
                    <span>{MISSING}</span>
                }}
            </Field>
            <Field label="Listed since">{day_long(profile.ipo) if profile.ipo else MISSING}</Field>
            <Field label="Fiscal year ends">{profile.fiscal_year_end[0:2] + "/" + profile.fiscal_year_end[2:4] if len(profile.fiscal_year_end) == 4 else MISSING}</Field>
            <Field label="SEC filer">
                {if profile.edgar_url {
                    <a href={profile.edgar_url} target="_blank" rel="noopener noreferrer" className="text-accent hover:underline">{"CIK " + profile.cik.lstrip("0")}</a>
                } else {
                    <span>{MISSING}</span>
                }}
            </Field>
        </dl>
    </div>
}

def margin_of(p: PeriodData) -> str {
    revenue = p.values.get("revenue");
    net = p.values.get("net_income");
    return pct(net / revenue, 1) if revenue and net is not None else MISSING;
}

def Performance(stock: StockData) -> JsxElement {
    has quarterly: bool = False;

    periods = stock.quarterly if quarterly else stock.annual;
    <Panel
        title="Performance"
        aside={
            <div className={SEGMENTS}>
                <button type="button" aria-pressed={not quarterly} className={"press h-full rounded-[3px] px-2.5 text-[12px] font-medium " + ("bg-panel text-text" if not quarterly else "text-muted hover:text-text")} onClick={lambda { quarterly = False; }}>Annual</button>
                <button type="button" aria-pressed={quarterly} className={"press h-full rounded-[3px] px-2.5 text-[12px] font-medium " + ("bg-panel text-text" if quarterly else "text-muted hover:text-text")} onClick={lambda { quarterly = True; }}>Quarterly</button>
            </div>
        }
    >
        <PeriodBars periods={periods} series={REVENUE_SERIES} footer_label="Net margin" footer={margin_of}/>
    </Panel>
}

def FinancialPanels(stock: StockData) -> JsxElement {
    if not has_figures(stock) {
        return <Panel title="Financials">
            <p className="max-w-[68ch] text-[13px] text-muted">No reported figures for this company. SEC's data covers U.S. GAAP reports in dollars, so a foreign filer that reports under IFRS or in its own currency has a profile and filings here but no financials, and a new listing has none until its first report.</p>
        </Panel>;
    }
    <div className="grid gap-4 lg:grid-cols-2">
        <Performance stock={stock}/>
        <Panel title="From revenue to profit" aside="Last twelve months">
            <ProfitSteps revenue={value_of(stock, "revenue_ttm")} gross={value_of(stock, "gross_profit_ttm")} operating={value_of(stock, "operating_income_ttm")} net={value_of(stock, "net_income_ttm")}/>
        </Panel>
        <Panel title="Debt and cash" aside="By fiscal year">
            <PeriodBars periods={stock.annual} series={DEBT_SERIES}/>
        </Panel>
        <Panel title="Returns and balance" aside={"Through " + day_short(word_of(stock, "report_period")) if word_of(stock, "report_period") else ""}>
            <div className="grid gap-x-8 sm:grid-cols-2">
                {for key_ in ["gross_margin", "operating_margin", "net_margin", "fcf_margin", "roe", "roa", "debt_to_equity", "current_ratio", "ps", "pb", "p_fcf", "ev_revenue"] {
                    <Field key={key_} label={label_for(key_)}>{show(key_, stock.values.get(key_))}</Field>
                }}
            </div>
        </Panel>
    </div>
}

def label_for(key_: str) -> str {
    return {
        "gross_margin": "Gross margin",
        "operating_margin": "Operating margin",
        "net_margin": "Net margin",
        "fcf_margin": "Free cash flow margin",
        "roe": "Return on equity",
        "roa": "Return on assets",
        "debt_to_equity": "Debt / equity",
        "current_ratio": "Current ratio",
        "ps": "Price / sales",
        "pb": "Price / book",
        "p_fcf": "Price / free cash flow",
        "ev_revenue": "EV / revenue"
    }.get(key_, key_);
}

def analyst_caption(stock: StockData) -> str {
    count_ = value_of(stock, "analyst_count");
    share = value_of(stock, "analyst_buy_share");
    if count_ is None {
        return "";
    }
    return num(count_, 0) + " analysts · " + pct(share, 0) + " rate it a buy";
}

def Gauges(stock: StockData) -> JsxElement {
    <div className="grid gap-6 sm:grid-cols-2">
        <Gauge title="Technicals" score={value_of(stock, "tech_score")} rating={word_of(stock, "tech_rating")} caption="Six indicators from daily bars"/>
        <Gauge title="Analyst rating" score={value_of(stock, "analyst_score")} rating={word_of(stock, "analyst_rating")} caption={analyst_caption(stock)}/>
    </div>
}

def vote_text(vote: int | None) -> str {
    if vote is None {
        return MISSING;
    }
    return "Buy" if vote > 0 else ("Sell" if vote < 0 else "Neutral");
}

"""An indicator's reading in its own unit: an average is a price, and momentum a percent."""
def signal_value(s: SignalData) -> str {
    if s.name.startswith("Price") {
        return money(s.value);
    }
    return signed_pct(s.value) if "momentum" in s.name else num(s.value);
}

def TechnicalsTab(stock: StockData) -> JsxElement {
    <div className="grid gap-4 lg:grid-cols-[1fr_1.4fr]">
        <Panel title="Rating">
            <Gauge title="Technicals" score={value_of(stock, "tech_score")} rating={word_of(stock, "tech_rating")} caption="The mean vote of the indicators beside it"/>
        </Panel>
        <Panel title="Indicators" pad={False}>
            <div className="scroll-x">
                <table className="w-full border-separate border-spacing-0">
                    <thead>
                        <tr>
                            <th scope="col" className={TH}>Indicator</th>
                            <th scope="col" className={TH_NUM}>Value</th>
                            <th scope="col" className={TH_NUM}>Vote</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for s in stock.signals {
                            <tr key={s.name} className={ROW}>
                                <td className={TD}>{s.name}</td>
                                <td className={TD_NUM}>{signal_value(s)}</td>
                                <td className={TD_NUM + " font-medium " + ("text-up" if s.vote is not None and s.vote > 0 else ("text-down" if s.vote is not None and s.vote < 0 else "text-muted"))}>{vote_text(s.vote)}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
        </Panel>
        <Panel title="Performance" className="lg:col-span-2">
            <div className="grid grid-cols-3 gap-3 sm:grid-cols-6">
                {for (label, key_) in [("1 week", "perf_1w"), ("1 month", "perf_1m"), ("3 months", "perf_3m"), ("6 months", "perf_6m"), ("Year to date", "perf_ytd"), ("1 year", "perf_1y")] {
                    <div key={key_}>
                        <Overline className="truncate">{label}</Overline>
                        <div className={"num mt-1 text-[15px] font-medium " + tone_of(key_, stock.values.get(key_))}>{show(key_, stock.values.get(key_))}</div>
                    </div>
                }}
            </div>
        </Panel>
    </div>
}

def ForecastsTab(stock: StockData) -> JsxElement {
    <div className="grid gap-4 lg:grid-cols-2">
        <Panel title="Analyst rating">
            <Gauge title="This month's consensus" score={value_of(stock, "analyst_score")} rating={word_of(stock, "analyst_rating")} caption={analyst_caption(stock)}/>
        </Panel>
        <Panel title="The consensus over time" aside="From all sell, down, to all buy, up">
            <RatingBars trend={stock.rating_trend}/>
        </Panel>
        <Panel title="Earnings" className="lg:col-span-2">
            <Earnings stock={stock}/>
        </Panel>
    </div>
}

def NewsList(about: AboutData | None, limit: int = 20) -> JsxElement {
    items = about.news[0:limit] if about is not None else [];
    if about is None {
        return <p className="text-[13px] text-muted">Loading headlines.</p>;
    }
    if about.busy and len(items) == 0 {
        return <p className="text-[13px] text-muted">Too many pages asked at once. This will fill in shortly.</p>;
    }
    if len(items) == 0 {
        return <p className="text-[13px] text-muted">No recent headlines for this stock.</p>;
    }
    <ul className="divide-y divide-line">
        {for item in items {
            <li key={item.url}>
                <a href={item.url} target="_blank" rel="noopener noreferrer" className="group/news flex items-start justify-between gap-3 py-2.5">
                    <span className="min-w-0">
                        <span className="block text-[13px] text-text group-hover/news:text-accent">{item.headline}</span>
                        <span className="num mt-0.5 block text-[11px] text-faint">{stamp_et(item.at) + (" · " + item.source if item.source else "")}</span>
                    </span>
                    <ExternalLink size={12} className="mt-1 shrink-0 text-faint" aria-hidden="true"/>
                </a>
            </li>
        }}
    </ul>
}

def FilingsList(stock: StockData, limit: int = 25) -> JsxElement {
    filings = stock.filings[0:limit];
    if len(filings) == 0 {
        return <p className="text-[13px] text-muted">No filings read yet for this company.</p>;
    }
    <ul className="divide-y divide-line">
        {for f in filings {
            <li key={f.url}>
                <a href={f.url} target="_blank" rel="noopener noreferrer" className="group/filing flex items-center justify-between gap-3 py-2.5">
                    <span className="flex min-w-0 items-center gap-3">
                        <span className={PILL_BASE + " " + TONE_ACCENT}>{f.form}</span>
                        <span className="num truncate text-[13px] text-text group-hover/filing:text-accent">{"Filed " + day_long(f.filed)}</span>
                    </span>
                    <ExternalLink size={12} className="shrink-0 text-faint" aria-hidden="true"/>
                </a>
            </li>
        }}
    </ul>
}

def:pub StockPage -> JsxElement {
    has stock: StockData | None = None,
        history: HistoryData | None = None,
        about: AboutData | None = None,
        compared: list[str] = [],
        compare_lines: list[CompareLine] = [],
        stars: list[str] = watched(),
        loaded: bool = False,
        error: str = "";

    params = useParams();
    symbol: str = str(params["symbol"] or "").upper();
    tab: str = params["tab"] or "";

    useEffect(
        lambda {
            active = True;
            timers: list[any] = [];
            loaded = False;
            error = "";
            stock = None;
            history = None;
            about = None;
            compared = [];
            compare_lines = [];
            async def load_history {
                try {
                    found = await get_stock_history(symbol);
                    if not active {
                        return;
                    }
                    history = found;
                    if found.busy {
                        timers.append(setTimeout(load_history, BUSY_RETRY_MS));
                    }
                } except Exception as e {
                    if active {
                        history = HistoryData(symbol=symbol);
                    }
                }
            }
            async def load_about {
                try {
                    found = await get_stock_about(symbol);
                    if not active {
                        return;
                    }
                    about = found;
                    if found.busy {
                        timers.append(setTimeout(load_about, BUSY_RETRY_MS));
                    }
                } except Exception as e {
                    if active {
                        about = AboutData(symbol=symbol);
                    }
                }
            }
            async def load {
                try {
                    found = await get_stock(symbol);
                    if active {
                        stock = found;
                    }
                } except Exception as e {
                    if active {
                        error = str(e);
                    }
                }
                if active {
                    loaded = True;
                }
                load_history();
                load_about();
            }
            load();
            return lambda {
                active = False;
                for timer in timers {
                    clearTimeout(timer);
                }
            };
        },
        [symbol]
    );

    async def toggle_compare(peer: str) {
        if peer in compared {
            compared = [s for s in compared if s != peer];
            compare_lines = [l for l in compare_lines if l.symbol != peer];
            return;
        }
        if len(compared) >= MAX_COMPARE {
            return;
        }
        compared = compared + [peer];
        found = await get_stock_history(peer);
        if len(found.daily) > 0 {
            compare_lines = compare_lines + [CompareLine(symbol=peer, daily=found.daily, intraday=found.intraday)];
        } else {
            compared = [s for s in compared if s != peer];
        }
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if not loaded {
        return <Loading label={"Loading " + symbol}/>;
    }
    if stock is None or not stock.found {
        return (
            <Empty title={symbol + " is not on the screener"}>
                It may be a fund, a warrant, or a company outside the U.S. exchanges, or its data may still be on its way. <Link to="/screener" className="text-accent hover:underline">Back to the screener</Link>
            </Empty>
        );
    }

    chart_daily: list[BarData] = history.daily if history is not None else [];
    chart_intraday: list[BarData] = history.intraday if history is not None else [];
    seasons = history.seasons if history is not None else [];
    starred = symbol in stars;

    <div className="rise flex flex-col gap-4">
        <div className="flex flex-col gap-3">
            <Breadcrumbs stock={stock}/>
            <Header stock={stock} starred={starred} star={lambda { stars = toggle_watch(symbol); }}/>
        </div>
        <Tabs symbol={symbol} active={tab}/>

        {if tab == "" {
            <div className="flex flex-col gap-4">
                <Panel title="Chart" pad={False}>
                    {if history is None {
                        <div className="h-[420px] animate-pulse bg-panel-2" aria-busy="true" aria-label="Loading the chart"></div>
                    } else {
                        <PriceChart symbol={symbol} daily={chart_daily} intraday={chart_intraday} compare={compare_lines}/>
                    }}
                </Panel>
                {if len(stock.peers) > 0 {
                    <section aria-label="Peers for comparison">
                        <h2 className="mb-2 text-[15px] font-medium text-text">Peers for comparison</h2>
                        <PeerCards peers={stock.peers} compared={compared} toggle={toggle_compare}/>
                    </section>
                }}
                <Panel title="Key stats" pad={False}><KeyStats stock={stock}/></Panel>
                <Panel title="Today's trading"><KeyFacts stock={stock}/></Panel>
                <div className="grid gap-4 lg:grid-cols-2">
                    <Panel title="Earnings"><Earnings stock={stock}/></Panel>
                    <Panel title="Ratings"><Gauges stock={stock}/></Panel>
                </div>
                <Panel title="About the company"><CompanyInfo stock={stock} about={about}/></Panel>
                <FinancialPanels stock={stock}/>
                <div className="grid gap-4 lg:grid-cols-2">
                    <Panel title="Headlines"><NewsList about={about} limit={6}/></Panel>
                    <Panel title="Recent filings"><FilingsList stock={stock} limit={6}/></Panel>
                </div>
            </div>
        } elif tab == "financials" {
            <FinancialPanels stock={stock}/>
        } elif tab == "technicals" {
            <TechnicalsTab stock={stock}/>
        } elif tab == "forecasts" {
            <ForecastsTab stock={stock}/>
        } elif tab == "seasonals" {
            <Panel title="Returns by month" aside="From daily closes since 2016">
                {if history is None {
                    <p className="text-[13px] text-muted">Loading.</p>
                } elif len(seasons) == 0 {
                    <p className="text-[13px] text-muted">No price history for this stock.</p>
                } else {
                    <SeasonTable seasons={seasons}/>
                }}
            </Panel>
        } elif tab == "news" {
            <Panel title="Headlines"><NewsList about={about}/></Panel>
        } elif tab == "filings" {
            <Panel title="SEC filings"><FilingsList stock={stock}/></Panel>
        } else {
            <Empty title="No such section">Choose one of the tabs above.</Empty>
        }}
    </div>
}

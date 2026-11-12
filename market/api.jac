"""The market pages' endpoints: read-only, and for signed-in readers, like the rest of the app.

`screen_stocks` and `get_stock` read only what the refresh passes keep in memory, so they spend no
provider calls and answer in milliseconds. `get_stock_history` and `get_stock_about` may reach a
provider on a cache miss, under the shared allowance in market/ondemand.jac. A symbol that is not a
covered stock is turned away before anything is fetched.
"""
import logging;
import re;
import threading;
import from datetime { date, datetime, time as day_time, timezone }
import from dashboard.api { get_portfolio, my_latest_run }
import from market.companies { CompanyRecord }
import from market.demo { demo_history, demo_intraday, demo_state }
import from run.switches { demo_mode }
import from market.ondemand { Busy, stock_description, stock_history, stock_intraday, stock_news }
import from market.prices { technical_signals }
import from market.query { as_count, as_flag, as_list, as_text, peers_of, read_filters, run_query }
import from market.rows { build_rows }
import from market.sectors { SECTORS }
import from market.state { MarketState, STATE }
import from models.market {
    BarView,
    CommitteeView,
    CoverageView,
    FilingView,
    HistoryView,
    NewsItemView,
    PeerView,
    PeriodView,
    ProfileView,
    RatingPointView,
    ScreenerView,
    SeasonView,
    SignalView,
    StockAboutView,
    StockView,
    SurpriseView
}
import from research.alpaca { Bar, MARKET_TZ }
import from research.collector { MissingKey, SourceError }

glob LOG: logging.Logger = logging.getLogger("trading_agent.market");
glob SYMBOL: re.Pattern[str] = re.compile(r"[A-Z][A-Z0-9.]{0,9}");
glob PAGE_ROWS: int = 100;
glob ALWAYS_SHOWN: list[str] = ["symbol", "name", "kind", "sp500"];
glob EDGAR: str = "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=";
glob SESSION_OPEN: day_time = day_time(9, 30);
glob SESSION_CLOSE: day_time = day_time(16, 0);
glob PRE_OPEN: day_time = day_time(4, 0);
glob POST_CLOSE: day_time = day_time(20, 0);

"""The rows as of one state version and day, indexed for the endpoints."""
obj RowCache {
    has version: int = -1,
        day: str = "",
        rows: list[dict[str, float | str | None]] = [],
        by_symbol: dict[str, dict[str, float | str | None]] = {},
        fields: set[str] = set(),
        exchanges: list[str] = [],
        state_id: int = 0;
}

"""The endpoints' shared answers: the latest rows and, on a demo server, today's invented market."""
obj Held {
    has rows: RowCache = RowCache(),
        demo: MarketState | None = None,
        demo_day: str = "";
}

glob HELD: Held = Held();
glob _ROWS_LOCK: threading.Lock = threading.Lock();

def is_demo -> bool {
    return demo_mode();
}

def today_et -> date {
    return datetime.now(MARKET_TZ).date();
}

"""The state to answer from: a demo server's invented market, or the live one loaded from disk."""
def market_state -> MarketState {
    if is_demo() {
        today = today_et();
        if HELD.demo is None or HELD.demo_day != today.isoformat() {
            HELD.demo = demo_state(today);
            HELD.demo_day = today.isoformat();
        }
        return HELD.demo;
    }
    STATE.load();
    return STATE;
}

"""The current rows, rebuilt only when the state or the day has changed. Readers take the swap in
one assignment, so a build under way never shows them half a table."""
def current_rows(state: MarketState) -> RowCache {
    today = today_et();
    day = today.isoformat();
    cached = HELD.rows;
    if cached.version == state.version and cached.day == day and cached.state_id == id(state) {
        return cached;
    }
    with _ROWS_LOCK {
        cached = HELD.rows;
        if cached.version == state.version and cached.day == day and cached.state_id == id(state) {
            return cached;
        }
        version = state.version;
        rows = build_rows(state, today);
        fresh = RowCache(
            version=version,
            day=day,
            rows=rows,
            by_symbol={str(r["symbol"]): r for r in rows},
            fields=set(rows[0]) if rows else set(),
            exchanges=sorted({str(r["exchange"]) for r in rows if r.get("exchange")}),
            state_id=id(state)
        );
        HELD.rows = fresh;
        return fresh;
    }
}

def coverage_of(rows: list[dict[str, float | str | None]]) -> CoverageView {
    return CoverageView(
        stocks=len(rows),
        priced=sum(1 for r in rows if r.get("price") is not None),
        with_stats=sum(1 for r in rows if r.get("rsi_14") is not None),
        with_figures=sum(1 for r in rows if r.get("revenue_ttm") is not None or r.get("net_income_ttm") is not None),
        with_analysts=sum(1 for r in rows if r.get("analyst_score") is not None)
    );
}

"""One page of the screener. `columns` picks which fields each row carries; empty means them all.
`filters` is described in market/query.jac, `symbols` limits it to a watchlist, and an unknown field or
unusable bound is left out rather than refused, so an old link still opens."""
def:priv screen_stocks(
    filters: list[dict[str, any]] = [],
    search: str = "",
    symbols: list[str] = [],
    sort: str = "market_cap",
    descending: bool = True,
    columns: list[str] = [],
    offset: int = 0,
    limit: int = PAGE_ROWS
) -> ScreenerView {
    state = market_state();
    cache = current_rows(state);
    wanted = read_filters(as_list(filters), cache.fields);
    named = as_text(sort);
    order = named if named in cache.fields else "market_cap";
    only = [str(s) for s in as_list(symbols)];
    (page, total) = run_query(cache.rows, wanted, as_text(search), only, order, as_flag(descending, True), as_count(offset, 0), as_count(limit, PAGE_ROWS));
    keep = [c for c in as_list(columns) if isinstance(c, str) and c in cache.fields];
    if keep {
        fields = list(dict.fromkeys(ALWAYS_SHOWN + keep));
        page = [{f: r.get(f) for f in fields} for r in page];
    }
    quote_days = [str(r.get("quote_day")) for r in cache.rows if r.get("quote_day")];
    (decided_day, decisions) = decisions_on({str(r.get("symbol")) for r in page});
    return ScreenerView(
        rows=page,
        decisions=decisions,
        decided_day=decided_day,
        total=total,
        ready=bool(cache.rows),
        demo=state.demo,
        as_of=state.meta.get("quotes_at", ""),
        quote_day=max(quote_days) if quote_days else "",
        sectors=SECTORS,
        exchanges=cache.exchanges,
        coverage=coverage_of(cache.rows)
    );
}

"""Which part of the trading day New York is in, for the page's header."""
def market_phase(now: datetime, sessions: str) -> str {
    local = now.astimezone(MARKET_TZ);
    today = local.date().isoformat();
    days = sessions.split(",") if sessions else [];
    is_session = today in days if days else local.weekday() < 5;
    if not is_session {
        return "closed";
    }
    moment = local.time();
    if moment < PRE_OPEN or moment >= POST_CLOSE {
        return "closed";
    }
    if moment < SESSION_OPEN {
        return "pre-market";
    }
    return "open" if moment < SESSION_CLOSE else "after-hours";
}

def peer_view(row: dict[str, any]) -> PeerView {
    return PeerView(
        symbol=str(row["symbol"]),
        name=str(row["name"]),
        price=row.get("price"),
        change_pct=row.get("change_pct"),
        market_cap=row.get("market_cap"),
        pe=row.get("pe")
    );
}

def period_views(periods: list) -> list[PeriodView] {
    return [PeriodView(end=p.end, label=p.label, values=p.values) for p in periods];
}

"""What the reader's own agent last did about a stock, from its views, which are cached already. A
reader of a stock page must not pay for a walk of the graph."""
def committee_of(symbol: str) -> CommitteeView {
    found = CommitteeView();
    try {
        for position in get_portfolio().positions {
            if position.ticker == symbol {
                found.held = True;
                found.held_qty = position.qty;
            }
        }
        run = my_latest_run();
        if run is not None {
            for row in run.rows {
                if row.ticker == symbol {
                    found.run_day = run.run_date;
                    found.action = row.action;
                    found.trail = f"/app/runs/{run.run_date}/{symbol}";
                }
            }
        }
    } except Exception as e {
        LOG.warning("market: no committee view for %s: %r", symbol, e);
    }
    return found;
}

"""The reader's agent's latest run day and the action it decided on each of `symbols` that run
covered, from the cached run view, as `committee_of` reads it."""
def decisions_on(symbols: set[str]) -> tuple[str, dict[str, str]] {
    try {
        run = my_latest_run();
        if run is None {
            return ("", {});
        }
        return (run.run_date, {row.ticker: row.action for row in run.rows if row.ticker in symbols and row.action});
    } except Exception as e {
        LOG.warning("market: no decisions for the screener: %r", e);
    }
    return ("", {});
}

def profile_view(listing_cik: str, record: CompanyRecord | None, website: str, ipo: str) -> ProfileView {
    profile = record.profile if record else None;
    place = ", ".join(p for p in [profile.city, profile.region] if p) if profile else "";
    return ProfileView(
        cik=listing_cik,
        headquarters=place,
        incorporated=profile.incorporated if profile else "",
        fiscal_year_end=profile.fiscal_year_end if profile else "",
        ein=profile.ein if profile else "",
        sic=profile.sic if profile else 0,
        sic_description=profile.sic_description if profile else "",
        filer_category=profile.filer_category if profile else "",
        website=website,
        ipo=ipo,
        edgar_url=EDGAR + str(int(listing_cik)) if listing_cik.isdigit() else ""
    );
}

"""A stock's page, without its long history and news, or `found=False` for anything uncovered."""
def:priv get_stock(symbol: str) -> StockView {
    wanted = as_text(symbol).strip().upper();
    state = market_state();
    cache = current_rows(state);
    row = cache.by_symbol.get(wanted);
    listing = state.listings.get(wanted);
    if row is None or listing is None {
        return StockView(found=False, symbol=wanted[:12], demo=state.demo);
    }
    record = state.company(listing.cik);
    analyst = state.analysts.get(wanted);
    stats = state.stats.get(wanted);
    quote = state.quotes.get(wanted);
    signals = technical_signals(quote.price, stats) if stats is not None and quote is not None else [];
    return StockView(
        found=True,
        symbol=wanted,
        name=listing.name,
        demo=state.demo,
        as_of=state.meta.get("quotes_at", ""),
        market_phase=market_phase(datetime.now(timezone.utc), state.meta.get("sessions", "")),
        values=row,
        profile=profile_view(listing.cik, record, analyst.website if analyst else "", analyst.ipo if analyst else ""),
        peers=[peer_view(p) for p in peers_of(row, cache.rows)],
        annual=period_views(record.annual) if record else [],
        quarterly=period_views(record.quarterly) if record else [],
        filings=[FilingView(form=f.form, filed=f.filed, report_date=f.report_date, url=f.url) for f in record.filings] if record else [],
        signals=[SignalView(name=s.name, value=s.value, vote=s.vote) for s in signals],
        rating_trend=[RatingPointView(period=p.period, score=p.score, analysts=p.analysts) for p in analyst.trend] if analyst else [],
        surprises=[SurpriseView(period=s.period, surprise_pct=s.surprise_pct) for s in analyst.surprises] if analyst else [],
        committee=committee_of(wanted)
    );
}

def bar_view(bar: Bar) -> BarView {
    return BarView(time=bar.day, open=bar.open, high=bar.high, low=bar.low, close=bar.close, volume=bar.volume);
}

"""An intraday bar's time, in Unix seconds as the chart reads it."""
def intraday_view(bar: Bar) -> BarView {
    moment = datetime.fromisoformat(bar.day.replace("Z", "+00:00"));
    return BarView(time=int(moment.timestamp()), open=bar.open, high=bar.high, low=bar.low, close=bar.close, volume=bar.volume);
}

"""Returns by calendar month, newest year first, from daily closes. A month's return is its last
close over the month before's, so a stock's first partial month and year have none."""
def seasons_of(bars: list[Bar]) -> list[SeasonView] {
    month_ends: dict[tuple[int, int], float] = {};
    for bar in bars {
        month_ends[(int(bar.day[:4]), int(bar.day[5:7]))] = bar.close;
    }
    ordered = sorted(month_ends);
    returns: dict[tuple[int, int], float] = {};
    for (before, month) in zip(ordered, ordered[1:]) {
        if month_ends[before] > 0 {
            returns[month] = month_ends[month] / month_ends[before] - 1.0;
        }
    }
    seasons: list[SeasonView] = [];
    for year in sorted({m[0] for m in returns}, reverse=True) {
        months: list[float | None] = [returns.get((year, m)) for m in range(1, 13)];
        total = 1.0;
        for value in months {
            if value is not None {
                total *= 1.0 + value;
            }
        }
        seasons.append(SeasonView(year=year, months=months, total=total - 1.0));
    }
    return seasons;
}

"""A stock's long price history and five sessions of intraday bars, for the chart and seasonals.
`busy` asks the page to retry; a provider failure returns what there is, which may be nothing."""
def:priv get_stock_history(symbol: str) -> HistoryView {
    wanted = as_text(symbol).strip().upper();
    state = market_state();
    if wanted not in state.listings or not SYMBOL.fullmatch(wanted) {
        return HistoryView(symbol=wanted[:12]);
    }
    if state.demo {
        daily = demo_history(wanted, today_et());
        return HistoryView(
            symbol=wanted,
            daily=[bar_view(b) for b in daily],
            intraday=[intraday_view(b) for b in demo_intraday(wanted, today_et())],
            seasons=seasons_of(daily)
        );
    }
    try {
        daily = stock_history(wanted);
    } except Busy {
        return HistoryView(symbol=wanted, busy=True);
    } except (MissingKey, SourceError) as e {
        LOG.warning("market: no history for %s: %s", wanted, e);
        return HistoryView(symbol=wanted);
    }
    view = HistoryView(symbol=wanted, daily=[bar_view(b) for b in daily], seasons=seasons_of(daily));
    try {
        view.intraday = [intraday_view(b) for b in stock_intraday(wanted)];
    } except (Busy, MissingKey, SourceError) as e {
        LOG.info("market: no intraday bars for %s: %r", wanted, e);
    }
    return view;
}

"""A stock's headlines and description. Each is on its own, so one failing leaves the other."""
def:priv get_stock_about(symbol: str) -> StockAboutView {
    wanted = as_text(symbol).strip().upper();
    state = market_state();
    listing = state.listings.get(wanted);
    if listing is None or not SYMBOL.fullmatch(wanted) {
        return StockAboutView(symbol=wanted[:12]);
    }
    view = StockAboutView(symbol=wanted);
    if state.demo {
        view.description = f"{listing.name} is shown here with invented figures. On a live server, this space holds the opening of the company's Wikipedia article.";
        return view;
    }
    try {
        view.news = [NewsItemView(headline=h.headline, source=h.source, url=h.url, at=h.at) for h in stock_news(wanted)];
    } except Busy {
        view.busy = True;
    } except (MissingKey, SourceError) as e {
        LOG.warning("market: no news for %s: %s", wanted, e);
    }
    try {
        (view.description, view.description_url) = stock_description(wanted, listing.name, listing.exchange);
    } except Busy {
        view.busy = True;
    } except (SourceError, ValueError, KeyError) as e {
        LOG.warning("market: no description for %s: %r", wanted, e);
    }
    return view;
}

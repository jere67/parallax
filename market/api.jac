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
import from dashboard.api { get_portfolio, my_latest_coin_run, my_latest_stock_run }
import from market.chain { ChainQuote, chain_quotes, chain_rows, demo_chain, expiries_of, listed_contracts }
import from market.coins { coin_row, coin_rows }
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
    CoinView,
    OptionBookView,
    OptionChainView,
    OptionHoldingView,
    OptionSideView,
    OptionStrikeView,
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
import from research.options { describe_option, parse_occ }

glob LOG: logging.Logger = logging.getLogger("trading_agent.market");
glob SYMBOL: re.Pattern[str] = re.compile(r"[A-Z][A-Z0-9.]{0,9}");
glob COIN: re.Pattern[str] = re.compile(r"[A-Z0-9]{1,15}/USD");
glob COIN_ALWAYS_SHOWN: list[str] = ["symbol", "name", "kind"];
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

"""What the reader's own agent last did about a stock or, for a pair, a coin, from its views, which
are cached already. A reader of a stock page must not pay for a walk of the graph."""
def committee_of(symbol: str) -> CommitteeView {
    found = CommitteeView();
    try {
        for position in get_portfolio().positions {
            if position.ticker == symbol {
                found.held = True;
                found.held_qty = position.qty;
            }
        }
        run = my_latest_coin_run() if "/" in symbol else my_latest_stock_run();
        if run is not None {
            for row in run.rows {
                if row.ticker == symbol {
                    found.run_day = run.run_date;
                    found.action = row.action;
                    found.trail = f"/app/runs/{run.run_date}/{symbol.replace('/', '-')}";
                }
            }
        }
    } except Exception as e {
        LOG.warning("market: no committee view for %s: %r", symbol, e);
    }
    return found;
}

"""The reader's agent's latest run day and the action it decided on each of `symbols` that run
covered, from the cached run view, as `committee_of` reads it: its latest run that covered coins
when `coins`, and stocks otherwise."""
def decisions_on(symbols: set[str], coins: bool = False) -> tuple[str, dict[str, str]] {
    try {
        run = my_latest_coin_run() if coins else my_latest_stock_run();
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

# --- Coins ---------------------------------------------------------------------------------

"""A pair as the pages write it, "BTC/USD" or "BTC-USD" (a page address cannot hold a slash), or ""
for anything else."""
def coin_symbol(text: str) -> str {
    pair = str(text).strip().upper().replace("-", "/");
    return pair if COIN.fullmatch(pair) else "";
}

"""One page of the crypto screener: every pair Alpaca trades against the dollar, filtered and
sorted as `screen_stocks` does, from what the refresh passes keep in memory."""
def:priv screen_coins(
    filters: list[dict[str, any]] = [],
    search: str = "",
    symbols: list[str] = [],
    sort: str = "dollar_volume",
    descending: bool = True,
    columns: list[str] = [],
    offset: int = 0,
    limit: int = PAGE_ROWS
) -> ScreenerView {
    state = market_state();
    rows = coin_rows(state.coins, state.coin_prices, state.coin_stats);
    fields: set[str] = set(rows[0]) if rows else set();
    wanted = read_filters(as_list(filters), fields);
    named = as_text(sort);
    order = named if named in fields else "dollar_volume";
    only = [coin_symbol(str(s)) for s in as_list(symbols) if coin_symbol(str(s))];
    (page, total) = run_query(rows, wanted, as_text(search), only, order, as_flag(descending, True), as_count(offset, 0), as_count(limit, PAGE_ROWS));
    keep = [c for c in as_list(columns) if isinstance(c, str) and c in fields];
    if keep {
        shown = list(dict.fromkeys(COIN_ALWAYS_SHOWN + keep));
        page = [{f: r.get(f) for f in shown} for r in page];
    }
    (decided_day, decisions) = decisions_on({str(r.get("symbol")) for r in page}, coins=True);
    return ScreenerView(
        rows=page,
        decisions=decisions,
        decided_day=decided_day,
        total=total,
        ready=bool(rows),
        demo=state.demo,
        as_of=state.meta.get("coin_prices_at", "") or state.meta.get("quotes_at", ""),
        quote_day=state.meta.get("coin_stats_day", ""),
        sectors=[],
        exchanges=[],
        coverage=CoverageView(
            stocks=len(rows),
            priced=sum(1 for r in rows if r.get("price") is not None),
            with_stats=sum(1 for r in rows if r.get("rsi_14") is not None)
        )
    );
}

"""A coin's page: its row, its kept daily bars, and what the reader's agent last did about it, or
`found=False` for a pair the screener does not cover."""
def:priv get_coin(symbol: str) -> CoinView {
    pair = coin_symbol(symbol);
    state = market_state();
    listing = state.coins.get(pair) if pair else None;
    if listing is None {
        return CoinView(found=False, symbol=pair or str(symbol));
    }
    daily = [
        BarView(time=str(b[0]), open=float(b[1]), high=float(b[2]), low=float(b[3]), close=float(b[4]), volume=float(b[5]))
        for b in state.coin_bars(pair) if len(b) == 6
    ];
    return CoinView(
        found=True,
        symbol=pair,
        name=listing.name,
        values=coin_row(listing, state.coin_prices.get(pair), state.coin_stats.get(pair)),
        daily=daily,
        committee=committee_of(pair),
        demo=state.demo,
        as_of=state.meta.get("coin_prices_at", "") or state.meta.get("quotes_at", ""),
        stats_day=state.meta.get("coin_stats_day", "")
    );
}

# --- Options -------------------------------------------------------------------------------

def side_view(q: ChainQuote | None, held: dict[str, float]) -> OptionSideView | None {
    if q is None {
        return None;
    }
    return OptionSideView(symbol=q.symbol, bid=q.bid, ask=q.ask, last=q.last, volume=q.volume, open_interest=q.open_interest, iv=q.iv, delta=q.delta, held=held.get(q.symbol, 0.0));
}

"""The contracts the reader's agent holds now, by OCC symbol."""
def held_contracts -> dict[str, float] {
    try {
        return {p.ticker: p.qty for p in get_portfolio().positions if parse_occ(p.ticker) is not None};
    } except Exception as e {
        LOG.warning("market: no option holdings: %r", e);
    }
    return {};
}

"""A stock's option chain for `expiry`, or its soonest listed expiry when `expiry` is not one, with
the reader's agent's contracts marked. A stock the screener does not cover is `found=False`."""
def:priv get_option_chain(symbol: str, expiry: str = "") -> OptionChainView {
    wanted = as_text(symbol).strip().upper();
    state = market_state();
    quote = state.quotes.get(wanted);
    if wanted not in state.listings or not SYMBOL.fullmatch(wanted) {
        return OptionChainView(symbol=wanted[:12]);
    }
    if quote is None or not quote.price {
        return OptionChainView(symbol=wanted, found=True, demo=state.demo, message="There is no price for this stock yet, so its chain cannot be centered.");
    }
    today = today_et();
    try {
        if state.demo {
            (contracts, quotes) = demo_chain(wanted, quote.price, today);
        } else {
            contracts = listed_contracts(wanted, quote.price, today);
            quotes = {};
        }
        expiries = expiries_of(contracts);
        if not expiries {
            return OptionChainView(symbol=wanted, found=True, price=quote.price, demo=state.demo, message="No listed options expire in the next four months.");
        }
        chosen = as_text(expiry) if as_text(expiry) in expiries else expiries[0];
        if not state.demo {
            quotes = chain_quotes([c.symbol for c in contracts if c.expiry == chosen]);
        }
    } except Busy {
        return OptionChainView(symbol=wanted, found=True, price=quote.price, demo=state.demo, busy=True);
    } except (MissingKey, SourceError) as e {
        LOG.warning("market: no option chain for %s: %s", wanted, e);
        return OptionChainView(symbol=wanted, found=True, price=quote.price, demo=state.demo, message="The option chain could not be read just now.");
    }
    held = held_contracts();
    rows = chain_rows(contracts, chosen, quotes);
    return OptionChainView(
        symbol=wanted,
        found=True,
        price=quote.price,
        expiries=expiries,
        expiry=chosen,
        strikes=[OptionStrikeView(strike=r.strike, call=side_view(r.call, held), put=side_view(r.put, held)) for r in rows],
        demo=state.demo
    );
}

"""Every option contract the reader's agent holds, has held, or has ordered, newest first: open
positions, then closed ones, then orders for contracts it never held."""
def:priv list_option_contracts -> OptionBookView {
    view = get_portfolio();
    today = today_et();
    rows: list[OptionHoldingView] = [];
    seen: set[str] = set();
    def holding(contract: str, status: str) -> OptionHoldingView | None {
        parts = parse_occ(contract);
        if parts is None {
            return None;
        }
        return OptionHoldingView(
            contract=contract,
            label=describe_option(contract),
            underlying=parts.underlying,
            kind=parts.kind,
            strike=parts.strike,
            expiry=parts.expiry,
            status=status,
            days_left=(date.fromisoformat(parts.expiry) - today).days
        );
    }
    for (positions, status) in [(view.positions, "Open"), (view.closed, "Closed")] {
        for p in positions {
            found = holding(p.ticker, status);
            if found is None {
                continue;
            }
            found.qty = p.qty if status == "Open" else p.entry_qty;
            found.entry_price = p.avg_entry_price;
            found.last = p.last_price if status == "Open" else p.exit_price;
            found.value = p.market_value if status == "Open" else None;
            found.pnl = p.pnl;
            found.pnl_pct = p.pnl_pct;
            found.decision_day = p.decision_day;
            found.at = p.opened_at if status == "Open" else p.closed_at;
            rows.append(found);
            seen.add(p.ticker);
        }
    }
    for o in view.orders {
        if o.ticker in seen {
            continue;
        }
        found = holding(o.ticker, "Ordered");
        if found is None {
            continue;
        }
        found.qty = o.qty;
        found.entry_price = o.filled_avg_price or o.limit_price;
        found.decision_day = o.run_day;
        found.at = o.submitted_at;
        rows.append(found);
        seen.add(o.ticker);
    }
    return OptionBookView(rows=rows, demo=view.demo);
}

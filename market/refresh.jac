"""Keeps the market pages' data current, a slice at a time.

A scheduled job fires every minute and starts two short background passes, each of which does what
is due until its deadline, keeps what it has, and picks up from there next minute. Nothing is lost
when the server restarts, and the first sweep of the whole market needs no special case: the table
fills in as it goes. The passes use threads of their own because they touch no graph (the collector
rule, TDD §3 rule 5) and so that the scheduler's other jobs never wait on them.

- Stocks: once a day, from SEC's ticker file and Alpaca's assets.
- Quotes: every five minutes while any session is open, otherwise every six hours.
- Price stats: a year of daily bars for every stock, once each session, once its bar is final.
- Earnings dates: twice a day, in one or a few calls.
- Companies: each company's submissions once a day, and its facts when it has filed a new report.
  Most days most companies have not, so this is about one request per company.
- Analysts: three Finnhub calls per stock every few days, at a third of the allowance, since the
  free plan's calls per minute are shared with the morning run.

Sweeps of SEC and Finnhub pause around the morning run, which needs those sources more. The raw
cache is skipped: it would keep gigabytes of bodies that are reduced to kilobytes here.
"""
import logging;
import os;
import threading;
import time;
import from datetime { date, datetime, time as day_time, timedelta, timezone }
import from market.analysts { AnalystRecord, analyst_record }
import from market.companies { company_facts, company_record, submissions, wants_facts }
import from market.demo { DEMO_ENV }
import from market.listings { build_listings, listed_tickers }
import from market.prices { Quote, positive_bars, price_stats, snapshots }
import from market.state { CompanySummary, EarningsDates, MarketState, STATE, summary_of }
import from research.alpaca { BarSeries, MARKET_TZ, alpaca_data_client, assets, bars_final, daily_bars, market_calendar }
import from research.collector { BudgetExceeded, CacheEntry, MissingKey, RawCache, RunBudget, SourceClient, SourceError, run_budget }
import from research.finnhub { earnings_calendar, finnhub_client }
import from research.sec { sec_data_client }
import from research.wikipedia { constituents }

glob LOG: logging.Logger = logging.getLogger("trading_agent.market");
glob STOCK_DAYS: float = 1.0;
glob QUOTE_OPEN_SECONDS: float = 300.0;
glob QUOTE_CLOSED_SECONDS: float = 6 * 3600.0;
glob EARNINGS_SECONDS: float = 12 * 3600.0;
glob ANALYST_DAYS: int = 3;
glob PASS_SECONDS: float = 50.0;
glob ANALYST_STOCKS_PER_PASS: int = 6;
glob BAR_SYMBOLS: int = 300;
glob BAR_LOOKBACK_DAYS: int = 400;
glob EARNINGS_WINDOW_DAYS: int = 30;
glob MAX_ERRORS_IN_A_ROW: int = 5;
glob SESSION_START: day_time = day_time(4, 0);
glob SESSION_END: day_time = day_time(20, 15);
glob QUIET_START: day_time = day_time(7, 15);
glob QUIET_END: day_time = day_time(9, 45);
glob _MAIN_PASS: threading.Lock = threading.Lock();
glob _ANALYST_PASS: threading.Lock = threading.Lock();

"""A raw cache that keeps nothing, for sweeps that reduce what they fetch."""
obj NoCache(RawCache) {
    override def read(key: str, ttl_hours: float | None, now: datetime) -> CacheEntry | None {
        return None;
    }

    override def write(item: CacheEntry) { }
}

glob NO_CACHE: NoCache = NoCache();

"""`client` set up for a sweep: no raw cache, and one retry so an outage fails fast."""
def sweep_client(client: SourceClient) -> SourceClient {
    client.cache = NO_CACHE;
    client.max_retries = 1;
    return client;
}

def seconds_since(iso: str, now: datetime) -> float {
    if not iso {
        return float("inf");
    }
    try {
        return (now - datetime.fromisoformat(iso)).total_seconds();
    } except ValueError {
        return float("inf");
    }
}

"""Whether New York time is in the window around the morning run."""
def quiet(now: datetime) -> bool {
    local = now.astimezone(MARKET_TZ);
    return local.weekday() < 5 and QUIET_START <= local.time() < QUIET_END;
}

"""Whether any session, extended hours included, may be open at this New York time."""
def session_hours(now: datetime) -> bool {
    local = now.astimezone(MARKET_TZ);
    return local.weekday() < 5 and SESSION_START <= local.time() < SESSION_END;
}

def refresh_stocks(state: MarketState, now: datetime, budget: RunBudget) {
    if state.listings and seconds_since(state.meta.get("stocks_at", ""), now) < STOCK_DAYS * 86400.0 {
        return;
    }
    tickers = listed_tickers(budget);
    listed = assets(budget);
    members = constituents(budget);
    state.listings = build_listings(tickers, listed, members);
    state.meta["stocks_at"] = now.isoformat();
    state.save("listings");
    state.save("meta");
    LOG.info("market: %d stocks listed", len(state.listings));
}

def refresh_quotes(state: MarketState, now: datetime, budget: RunBudget) {
    interval = QUOTE_OPEN_SECONDS if session_hours(now) else QUOTE_CLOSED_SECONDS;
    if not state.listings or seconds_since(state.meta.get("quotes_at", ""), now) < interval {
        return;
    }
    fresh = snapshots(list(state.listings), budget, sweep_client(alpaca_data_client()));
    state.quotes = {**state.quotes, **fresh};
    state.meta["quotes_at"] = now.isoformat();
    state.save("quotes");
    state.save("meta");
}

"""The newest session whose bars are final, and whether today is a session at all."""
def final_session(now: datetime, budget: RunBudget) -> tuple[str, list[str]] {
    today = now.astimezone(MARKET_TZ).date();
    days = [d.day for d in market_calendar((today - timedelta(days=10)).isoformat(), (today + timedelta(days=5)).isoformat(), budget)];
    final = [d for d in days if bars_final(d, now)];
    return (final[-1] if final else "", days);
}

"""Reduce bars for the next stocks in line, until the pass ends or every stock is current."""
def refresh_stats(state: MarketState, now: datetime, deadline: float, budget: RunBudget) {
    if not state.listings {
        return;
    }
    (target, days) = final_session(now, budget);
    state.meta["sessions"] = ",".join(days);
    if not target or state.meta.get("stats_day") == target {
        return;
    }
    symbols = sorted(state.listings);
    if state.meta.get("stats_target") != target {
        state.meta["stats_target"] = target;
        state.meta["stats_cursor"] = "0";
    }
    cursor = int(state.meta.get("stats_cursor") or 0);
    start = (date.fromisoformat(target) - timedelta(days=BAR_LOOKBACK_DAYS)).isoformat();
    client = sweep_client(alpaca_data_client());
    (benchmarks, _) = daily_bars(["SPY"], start, target, budget, client);
    spy: BarSeries | None = benchmarks[0] if benchmarks else None;
    stats = dict(state.stats);
    while cursor < len(symbols) and time.monotonic() < deadline {
        chunk = symbols[cursor:cursor + BAR_SYMBOLS];
        (found, _) = daily_bars(chunk, start, target, budget, client);
        for series in found {
            series.bars = positive_bars(series.bars);
            if series.bars {
                stats[series.symbol] = price_stats(series, spy);
            }
        }
        cursor += len(chunk);
        state.meta["stats_cursor"] = str(cursor);
    }
    state.stats = stats;
    if cursor >= len(symbols) {
        state.meta["stats_day"] = target;
    }
    state.save("stats");
    state.save("meta");
}

def refresh_earnings(state: MarketState, now: datetime, budget: RunBudget) {
    if quiet(now) or seconds_since(state.meta.get("earnings_at", ""), now) < EARNINGS_SECONDS {
        return;
    }
    today = now.astimezone(MARKET_TZ).date();
    (releases, _) = earnings_calendar(
        (today - timedelta(days=EARNINGS_WINDOW_DAYS)).isoformat(),
        (today + timedelta(days=EARNINGS_WINDOW_DAYS)).isoformat(),
        budget
    );
    state.earnings = merged_earnings(state.earnings, [(r.symbol, r.day, r.hour) for r in releases], today.isoformat());
    state.meta["earnings_at"] = now.isoformat();
    state.save("earnings");
    state.save("meta");
}

"""Each stock's next and latest report dates from `releases` of (symbol, day, hour). A report date
older than the window stays from `earlier`, and a next date from `earlier` is dropped once past."""
def merged_earnings(earlier: dict[str, EarningsDates], releases: list[tuple[str, str, str]], today: str) -> dict[str, EarningsDates] {
    merged: dict[str, EarningsDates] = {};
    for (symbol, dates) in earlier.items() {
        last = max(dates.last_day, dates.next_day) if dates.next_day and dates.next_day < today else dates.last_day;
        merged[symbol] = EarningsDates(last_day=last);
    }
    for (symbol, day, hour) in sorted(releases, key=lambda (r: tuple[str, str, str]) { r[1]; }) {
        dates = merged.setdefault(symbol, EarningsDates());
        if day < today {
            dates.last_day = max(dates.last_day, day);
        } elif not dates.next_day {
            dates.next_day = day;
            dates.next_hour = hour;
        }
    }
    return merged;
}

"""What a stock's dollar volume was at the last quote, to sweep the most traded names first."""
def traded(state: MarketState, symbol: str) -> float {
    quote: Quote | None = state.quotes.get(symbol);
    return (quote.volume or 0.0) * quote.price if quote else 0.0;
}

"""Each company's CIK in sweep order: never read first, then index members, then the most traded."""
def company_queue(state: MarketState, today: str) -> list[str] {
    best: dict[str, tuple[bool, float]] = {};
    for listing in state.listings.values() {
        rank = (not listing.sp500, 0.0 - traded(state, listing.symbol));
        if listing.cik not in best or rank < best[listing.cik] {
            best[listing.cik] = rank;
        }
    }
    def checked(cik: str) -> str {
        summary = state.companies.get(cik);
        return summary.checked if summary else "";
    }
    due = [cik for cik in best if checked(cik) != today];
    return sorted(due, key=lambda (cik: str) { (checked(cik), best[cik]); });
}

"""Read the next companies in line until the pass ends. A company that fails is retried next time,
and several failures in a row end the pass, since then the source is down."""
def sweep_companies(state: MarketState, now: datetime, deadline: float, budget: RunBudget) {
    if quiet(now) {
        return;
    }
    client = sweep_client(sec_data_client());
    today = now.astimezone(MARKET_TZ).date().isoformat();
    companies = dict(state.companies);
    errors = 0;
    done = 0;
    for cik in company_queue(state, today) {
        if time.monotonic() >= deadline or errors >= MAX_ERRORS_IN_A_ROW {
            break;
        }
        try {
            found = submissions(cik, budget, client);
            earlier = state.company(cik);
            facts = None;
            if wants_facts(found, earlier) {
                try {
                    facts = company_facts(cik, budget, client);
                } except SourceError as e {
                    # A company with no XBRL facts answers 404, which is normal for a new listing.
                    if not isinstance(e, BudgetExceeded) and e.status != 404 {
                        raise e;
                    }
                }
            }
            record = company_record(cik, found, facts, today, earlier);
            state.save_company(record);
            companies[cik] = summary_of(record);
            done += 1;
            errors = 0;
        } except BudgetExceeded {
            break;
        } except SourceError as e {
            errors += 1;
            LOG.warning("market: %s: %s", cik, e);
        } except (ValueError, KeyError, TypeError, AttributeError) as e {
            # An unusual filer must not stop the sweep. Mark it read so it waits for tomorrow.
            LOG.warning("market: could not read company %s: %r", cik, e);
            earlier_summary = companies.get(cik);
            companies[cik] = CompanySummary(
                cik=cik,
                checked=today,
                facts_filed=earlier_summary.facts_filed if earlier_summary else "",
                report_filed=earlier_summary.report_filed if earlier_summary else "",
                period_end=earlier_summary.period_end if earlier_summary else "",
                sic=earlier_summary.sic if earlier_summary else 0,
                sic_description=earlier_summary.sic_description if earlier_summary else "",
                values=earlier_summary.values if earlier_summary else {}
            );
            done += 1;
            errors = 0;
        }
    }
    if done {
        state.companies = companies;
        state.save("companies");
    }
}

"""One pass over everything but analysts. A source that fails leaves its domain as it was."""
def main_pass(state: MarketState, now: datetime, deadline: float) {
    state.load();
    budget = run_budget();
    steps: list[tuple[str, Callable[[], None]]] = [
        ("stocks", lambda { refresh_stocks(state, now, budget); }),
        ("quotes", lambda { refresh_quotes(state, now, budget); }),
        ("earnings", lambda { refresh_earnings(state, now, budget); }),
        ("stats", lambda { refresh_stats(state, now, deadline, budget); }),
        ("companies", lambda { sweep_companies(state, now, deadline, budget); })
    ];
    for (name, step) in steps {
        try {
            step();
        } except MissingKey as e {
            LOG.info("market: skipping %s: %s", name, e);
        } except SourceError as e {
            LOG.warning("market: %s failed: %s", name, e);
        }
    }
}

"""The next stocks' Finnhub records, most traded first, a few a minute."""
def analyst_pass(state: MarketState, now: datetime) {
    state.load();
    if quiet(now) or not state.quotes {
        return;
    }
    today = now.astimezone(MARKET_TZ).date();
    cutoff = (today - timedelta(days=ANALYST_DAYS)).isoformat();
    def read_on(symbol: str) -> str {
        record = state.analysts.get(symbol);
        return record.checked if record else "";
    }
    due = [s for s in state.listings if read_on(s) <= cutoff];
    due.sort(key=lambda (s: str) { (read_on(s), not state.listings[s].sp500, 0.0 - traded(state, s)); });
    if not due {
        return;
    }
    client = sweep_client(finnhub_client());
    budget = run_budget();
    records = dict(state.analysts);
    for symbol in due[:ANALYST_STOCKS_PER_PASS] {
        quote = state.quotes.get(symbol);
        try {
            records[symbol] = analyst_record(symbol, quote.price if quote else None, today.isoformat(), budget, client);
        } except BudgetExceeded {
            break;
        } except SourceError as e {
            # Finnhub refuses some symbols outright, so one must not hold up the line behind it.
            LOG.warning("market: analysts %s: %s", symbol, e);
            kept = records.get(symbol) or AnalystRecord(symbol=symbol, checked="");
            kept.checked = today.isoformat();
            records[symbol] = kept;
        }
    }
    state.analysts = records;
    state.save("analysts");
}

def in_background(lock: threading.Lock, work: Callable[[], None]) {
    if not lock.acquire(blocking=False) {
        return;
    }
    def run {
        try {
            work();
        } except Exception as e {
            LOG.exception("market: a refresh pass failed: %r", e);
        } finally {
            lock.release();
        }
    }
    threading.Thread(target=run, name="market-refresh", daemon=True).start();
}

"""Starts this minute's passes, unless the last ones are still going. A demo server's market is
invented, so it has nothing to refresh."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def market_job {
    if os.environ.get(DEMO_ENV, "").strip() == "1" {
        return;
    }
    now = datetime.now(timezone.utc);
    in_background(_MAIN_PASS, lambda { main_pass(STATE, now, time.monotonic() + PASS_SECONDS); });
    in_background(_ANALYST_PASS, lambda { analyst_pass(STATE, now); });
}

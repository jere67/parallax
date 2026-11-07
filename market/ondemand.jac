"""What a stock's page fetches when it opens, rather than ahead of time for six thousand stocks:
its long price history, today's intraday bars, its headlines, and its description.

These endpoints are public, and each page view may reach a provider, unlike the rest of the
dashboard, so two things bound them. Answers are held in memory for a while, for any reader, and
only covered stocks can be asked for, so the set of possible requests is finite. And all pages
together share one small allowance per minute; past it a page hears `Busy` and retries, so traffic
can never take calls away from the morning run. Nothing here writes to disk.
"""
import json;
import threading;
import time;
import from datetime { datetime, timedelta, timezone }
import from urllib.parse { quote as url_quote }
import from market.prices { positive_bars }
import from market.refresh { NO_CACHE }
import from research.alpaca { Bar, MARKET_TZ, _bar, alpaca_data_client }
import from research.alpaca_news { _check_news }
import from research.collector { RunBudget, SourceClient, run_budget }
import from research.sources { DATASETS }
import from research.text { html_to_text }
import from research.wikipedia { wikipedia_client }

glob HISTORY_START: str = "2016-01-01";
glob BARS_PER_PAGE: int = 10000;
glob HISTORY_MAX_PAGES: int = 2;
glob NEWS_ITEMS: int = 20;
glob INTRADAY_DAYS: int = 9;
glob DELAY_MINUTES: int = 16;
glob HISTORY_SECONDS: float = 6 * 3600.0;
glob INTRADAY_SECONDS: float = 300.0;
glob NEWS_SECONDS: float = 1800.0;
glob ABOUT_SECONDS: float = 7 * 86400.0;
glob MAX_ENTRIES: int = 400;
glob CALLS_PER_MINUTE: float = 40.0;
glob CALL_BURST: float = 12.0;
glob DESCRIPTION_CHARS: int = 1200;
# Words too common in company names to show that a Wikipedia article is about this company.
glob NAME_NOISE: set[str] = {"the", "inc", "corp", "corporation", "company", "co", "ltd", "limited", "plc", "group", "holdings", "holding", "american", "first", "new", "united", "national", "global", "international", "of", "and"};

"""The shared allowance is spent for now; ask again in a little while."""
obj Busy(Exception) { }

"""The pages' shared allowance of provider calls, which refuses rather than waits."""
obj Allowance {
    has per_minute: float,
        burst: float;
    has _tokens: float = 0.0,
        _updated: float = 0.0,
        _lock: threading.Lock | None = None;

    def postinit {
        self._lock = threading.Lock();
        self._tokens = self.burst;
        self._updated = time.monotonic();
    }

    def take(calls: int = 1) {
        with self._lock {
            now = time.monotonic();
            self._tokens = min(self.burst, self._tokens + (now - self._updated) * self.per_minute / 60.0);
            self._updated = now;
            if self._tokens < calls {
                raise Busy();
            }
            self._tokens -= calls;
        }
    }
}

"""Answers held for a while; the oldest go first past MAX_ENTRIES."""
obj TimedCache {
    has entries: dict[str, tuple[float, any]] = {},
        _lock: threading.Lock | None = None;

    def postinit {
        self._lock = threading.Lock();
    }

    def get(key: str, seconds: float) -> any {
        with self._lock {
            found = self.entries.get(key);
            return found[1] if found is not None and time.monotonic() - found[0] < seconds else None;
        }
    }

    def put(key: str, value: any) {
        with self._lock {
            self.entries[key] = (time.monotonic(), value);
            while len(self.entries) > MAX_ENTRIES {
                oldest = min(self.entries, key=lambda (k: str) { self.entries[k][0]; });
                del self.entries[oldest];
            }
        }
    }
}

glob ALLOWANCE: Allowance = Allowance(per_minute=CALLS_PER_MINUTE, burst=CALL_BURST);
glob ANSWERS: TimedCache = TimedCache();

def on_demand_client(client: SourceClient) -> SourceClient {
    client.cache = NO_CACHE;
    client.max_retries = 1;
    client.timeout_s = 15.0;
    return client;
}

def _bars_of(symbol: str, dataset: str, query: dict[str, str | int | float], budget: RunBudget, max_pages: int) -> list[Bar] {
    client = on_demand_client(alpaca_data_client());
    found: list[Bar] = [];
    token = "";
    for _ in range(max_pages) {
        ALLOWANCE.take();
        params: dict[str, str | int | float] = {**query, "symbols": symbol, "limit": BARS_PER_PAGE, "feed": "sip"};
        if token {
            params["page_token"] = token;
        }
        page = json.loads(client.get(DATASETS[dataset], "/v2/stocks/bars", budget, params=params).body);
        found.extend(_bar(row) for row in (page.get("bars") or {}).get(symbol) or []);
        token = page.get("next_page_token") or "";
        if not token {
            break;
        }
    }
    return positive_bars(found);
}

"""Daily bars back to 2016, adjusted for splits and dividends. A symbol's raw `day` is its session.
Raises Busy when the allowance is spent."""
def stock_history(symbol: str) -> list[Bar] {
    key = f"history:{symbol}";
    found = ANSWERS.get(key, HISTORY_SECONDS);
    if found is not None {
        return found;
    }
    now = datetime.now(timezone.utc) - timedelta(minutes=DELAY_MINUTES);
    bars = _bars_of(
        symbol,
        "market.history",
        {"timeframe": "1Day", "start": HISTORY_START, "end": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "adjustment": "all"},
        run_budget(),
        HISTORY_MAX_PAGES
    );
    ANSWERS.put(key, bars);
    return bars;
}

"""Five-minute bars for the last sessions, in the regular session only. `day` holds the UTC time."""
def stock_intraday(symbol: str) -> list[Bar] {
    key = f"intraday:{symbol}";
    found = ANSWERS.get(key, INTRADAY_SECONDS);
    if found is not None {
        return found;
    }
    now = datetime.now(timezone.utc) - timedelta(minutes=DELAY_MINUTES);
    client = on_demand_client(alpaca_data_client());
    ALLOWANCE.take();
    page = json.loads(client.get(
        DATASETS["market.intraday"],
        "/v2/stocks/bars",
        run_budget(),
        params={
            "symbols": symbol,
            "timeframe": "5Min",
            "start": (now - timedelta(days=INTRADAY_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "adjustment": "all",
            "feed": "sip",
            "limit": BARS_PER_PAGE
        }
    ).body);
    bars = [_intraday_bar(row) for row in (page.get("bars") or {}).get(symbol) or []];
    kept = [b for b in bars if _in_session(b.day)];
    sessions = sorted({_session_day(b.day) for b in kept})[-5:];
    kept = [b for b in kept if _session_day(b.day) in sessions];
    ANSWERS.put(key, kept);
    return kept;
}

def _intraday_bar(row: dict[str, float | int | str]) -> Bar {
    return Bar(
        day=str(row["t"]),
        open=float(row["o"]),
        high=float(row["h"]),
        low=float(row["l"]),
        close=float(row["c"]),
        volume=float(row["v"]),
        trades=int(row.get("n") or 0),
        vwap=float(row.get("vw") or 0.0)
    );
}

def _local(at: str) -> datetime {
    return datetime.fromisoformat(at.replace("Z", "+00:00")).astimezone(MARKET_TZ);
}

def _session_day(at: str) -> str {
    return _local(at).date().isoformat();
}

def _in_session(at: str) -> bool {
    moment = _local(at);
    minutes = moment.hour * 60 + moment.minute;
    return 570 <= minutes < 960;
}

"""One headline, linking out to the article."""
obj Headline {
    has headline: str,
        source: str,
        url: str,
        at: str;
}

"""The newest headlines naming `symbol`, without article text."""
def stock_news(symbol: str) -> list[Headline] {
    key = f"news:{symbol}";
    found = ANSWERS.get(key, NEWS_SECONDS);
    if found is not None {
        return found;
    }
    ALLOWANCE.take();
    fetched = on_demand_client(alpaca_data_client()).get(
        DATASETS["market.news"],
        "/v1beta1/news",
        run_budget(),
        params={"symbols": symbol, "limit": NEWS_ITEMS, "sort": "desc", "include_content": "false", "exclude_contentless": "false"},
        check=_check_news
    );
    items = [
        Headline(
            headline=html_to_text(str(row.get("headline") or "")),
            source=str(row.get("source") or "").title(),
            url=str(row.get("url") or ""),
            at=str(row.get("created_at") or "")
        )
        for row in json.loads(fetched.body).get("news") or []
        if row.get("headline") and row.get("url")
    ];
    ANSWERS.put(key, items);
    return items;
}

"""The words that identify a company in an article's title."""
def name_words(name: str) -> set[str] {
    words = "".join(c.lower() if c.isalnum() else " " for c in name).split();
    return {w for w in words if w not in NAME_NOISE and len(w) > 1};
}

"""The first search hit whose title shares a distinctive word with the company's name: a page that
cites a ticker is often a list of companies, not the company itself."""
def matching_title(titles: list[str], company: str) -> str {
    wanted = name_words(company);
    for title in titles {
        if wanted & name_words(title) {
            return title;
        }
    }
    return "";
}

"""A short description and the article it came from, by finding the Wikipedia article that cites
the company's ticker in its infobox and reading its summary. ("", "") when none clearly matches: no
description beats another company's."""
def stock_description(symbol: str, company: str, exchange: str) -> tuple[str, str] {
    key = f"about:{symbol}";
    found = ANSWERS.get(key, ABOUT_SECONDS);
    if found is not None {
        return found;
    }
    client = on_demand_client(wikipedia_client());
    ALLOWANCE.take(2);
    market = "NASDAQ" if exchange == "Nasdaq" else "NYSE";
    searched = json.loads(client.get(
        DATASETS["market.search"],
        "/w/api.php",
        run_budget(),
        params={"action": "query", "list": "search", "srsearch": f'insource:"{market}|{symbol}"', "srlimit": 5, "format": "json"}
    ).body);
    title = matching_title([h["title"] for h in (searched.get("query") or {}).get("search") or []], company);
    answer = ("", "");
    if title {
        summary = json.loads(client.get(
            DATASETS["market.summary"],
            "/api/rest_v1/page/summary/" + url_quote(title.replace(" ", "_"), safe=""),
            run_budget()
        ).body);
        text = str(summary.get("extract") or "");
        page = ((summary.get("content_urls") or {}).get("desktop") or {}).get("page") or "";
        if text and summary.get("type") == "standard" {
            answer = (text[:DESCRIPTION_CHARS], str(page));
        }
    }
    ANSWERS.put(key, answer);
    return answer;
}

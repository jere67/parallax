"""The backtest harness's history (TDD §13, historical harness): point-in-time S&P 500
membership, daily bars, news counts, earnings release dates, and each member's sector.

Everything is fetched once and kept in the directory BACKTEST_CACHE names, so a rerun is
offline. Alpaca is held to ALPACA_PER_MINUTE requests a minute and waits out the live morning
run (QUIET_START to QUIET_END New York time on weekdays), since the server uses the same keys.

- Membership: `members_on` (research/wikipedia.jac) for every session, from today's list and
  the dated changes.
- Bars: `daily_bars` (research/alpaca.jac), adjusted, from the first session Alpaca has
  (January 4, 2016) on.
- News: every article naming a member, kept as its UTC timestamp and symbols, so the screen's
  three-session count can be rebuilt for any morning.
- Earnings: the filing dates of each company's 8-K Item 2.02 (results of operations) from the
  SEC's submissions files, as the release dates a calendar would have listed in advance.
- Sectors and CIKs: today's list, plus yearly revisions of the same Wikipedia table for
  companies that have since left the index.
"""
import gzip;
import json;
import os;
import re;
import sys;
import time;
import from datetime { date, datetime, timedelta, timezone }
import from pathlib { Path }
import from zoneinfo { ZoneInfo }
import httpx;
import from research.alpaca { Bar, alpaca_headers, daily_bars, market_calendar }
import from research.collector { RunBudget }
import from research.sec { padded_cik, sec_user_agent }
import from research.sources { SOURCES }
import from research.wikipedia { USER_AGENT, alpaca_symbol, constituents, index_changes, members_on, table_records }

glob CACHE_ENV: str = "BACKTEST_CACHE";
glob NEW_YORK: ZoneInfo = ZoneInfo("America/New_York");
glob ALPACA_PER_MINUTE: float = 120.0;
# Minutes after midnight New York time, on weekdays, when Alpaca is left to the live server.
glob QUIET_START: int = 7 * 60 + 15;
glob QUIET_END: int = 10 * 60;
# The SEC asks for at most 10 requests a second.
glob SEC_INTERVAL_S: float = 0.125;
glob BARS_START: str = "2015-01-01";
glob SYMBOLS_PER_CHUNK: int = 100;
glob NEWS_PAGE: int = 50;
glob NEWS_SYMBOLS_PER_REQUEST: int = 1000;
glob WIKI_API: str = "https://en.wikipedia.org/w/api.php";
glob LIST_TITLE: str = "List of S&P 500 companies";

"""The cache directory, created on first use."""
def cache_dir -> Path {
    found = Path(os.environ.get(CACHE_ENV, "backtest-cache"));
    found.mkdir(parents=True, exist_ok=True);
    return found;
}

"""The cached value under `name`, or None when there is none."""
def read_cached(name: str) -> any {
    path = cache_dir() / name;
    if not path.exists() {
        return None;
    }
    with gzip.open(path, "rt") as f {
        return json.load(f);
    }
}

"""Write `value` under `name` through a temporary file, so a stopped fetch never leaves half a file."""
def write_cached(name: str, value: any) {
    path = cache_dir() / name;
    path.parent.mkdir(parents=True, exist_ok=True);
    part = path.with_suffix(path.suffix + ".part");
    with gzip.open(part, "wt") as f {
        json.dump(value, f, separators=(",", ":"));
    }
    part.replace(path);
}

def say(text: str) {
    sys.stdout.write(f"[{datetime.now(NEW_YORK):%H:%M:%S}] {text}\n");
    sys.stdout.flush();
}

"""Seconds to wait before Alpaca may be called at `now`: until QUIET_END on a weekday
morning inside the quiet window, else 0."""
def quiet_wait(now: datetime) -> float {
    local = now.astimezone(NEW_YORK);
    minute = local.hour * 60 + local.minute;
    if local.weekday() >= 5 or not (QUIET_START <= minute < QUIET_END) {
        return 0.0;
    }
    return float((QUIET_END - minute) * 60 - local.second);
}

def wait_for_alpaca {
    pause = quiet_wait(datetime.now(timezone.utc));
    if pause > 0 {
        say(f"pausing Alpaca for the live morning run, {pause / 60:.0f} minutes");
        time.sleep(pause);
    }
}

"""A budget no fetch here can spend, and Alpaca's rate held to ALPACA_PER_MINUTE. Must run
before the first Alpaca request, since the token bucket is made then."""
def harness_budget -> RunBudget {
    for name in ["alpaca_data", "alpaca_trading"] {
        SOURCES[name].per_minute = ALPACA_PER_MINUTE;
        SOURCES[name].burst = min(SOURCES[name].burst, 5);
    }
    return RunBudget(limits={name: 10_000_000 for name in SOURCES});
}

"""Every session from `start` through `end`, from Alpaca's calendar."""
def sessions(start: str, end: str) -> list[str] {
    name = f"sessions-{start}-{end}.json.gz";
    found = read_cached(name);
    if found is None {
        wait_for_alpaca();
        found = [d.day for d in market_calendar(start, end, harness_budget())];
        write_cached(name, found);
    }
    return list(found);
}

"""Members on each of `days`, and the gaps `members_on` reported, deduplicated."""
def membership(days: list[str]) -> tuple[dict[str, list[str]], list[str]] {
    found = read_cached("membership.json.gz");
    if found is None or found.get("days") != days {
        budget = harness_budget();
        current = constituents(budget);
        (changes, change_gaps) = index_changes(budget);
        members: dict[str, list[str]] = {};
        gaps: set[str] = set(change_gaps);
        for d in days {
            m = members_on(d, current, changes);
            members[d] = m.symbols;
            gaps |= set(m.gaps);
        }
        found = {
            "days": days,
            "members": members,
            "gaps": sorted(gaps),
            "current": [{"symbol": c.symbol, "sector": c.sector, "cik": c.cik, "name": c.name} for c in current]
        };
        write_cached("membership.json.gz", found);
    }
    return (found["members"], found["gaps"]);
}

"""Today's members, with sector and CIK, from the cached membership."""
def current_members -> list[dict[str, str]] {
    found = read_cached("membership.json.gz");
    return list(found["current"]) if found else [];
}

"""Each symbol's daily bars, from BARS_START through `end`, fetched in chunks and cached per
chunk so a stopped fetch resumes. A symbol Alpaca has no bars for is left out."""
def bars(symbols: list[str], end: str) -> dict[str, list[Bar]] {
    wanted = sorted(set(symbols));
    found: dict[str, list[Bar]] = {};
    budget = harness_budget();
    for i in range(0, len(wanted), SYMBOLS_PER_CHUNK) {
        chunk = wanted[i:i + SYMBOLS_PER_CHUNK];
        name = f"bars/{end}-{chunk[0]}-{chunk[-1]}-{len(chunk)}.json.gz";
        rows = read_cached(name);
        if rows is None {
            wait_for_alpaca();
            (series, _gaps) = daily_bars(chunk, BARS_START, end, budget);
            rows = {s.symbol: [[b.day, b.open, b.high, b.low, b.close, b.volume, b.trades, b.vwap] for b in s.bars] for s in series};
            write_cached(name, rows);
            say(f"bars: {min(i + SYMBOLS_PER_CHUNK, len(wanted))} of {len(wanted)} symbols");
        }
        for (symbol, rows_) in rows.items() {
            found[symbol] = [Bar(day=r[0], open=r[1], high=r[2], low=r[3], close=r[4], volume=r[5], trades=int(r[6]), vwap=r[7]) for r in rows_];
        }
    }
    return found;
}

"""Every article naming one of `symbols` in each calendar month from `start` through `end`, as
[created_at, [symbols]], cached per month."""
def news(symbols: list[str], start: str, end: str) -> dict[str, list[list[object]]] {
    wanted = sorted(set(symbols));
    months: list[str] = [];
    cursor = date.fromisoformat(start).replace(day=1);
    while cursor.isoformat() <= end {
        months.append(cursor.isoformat()[:7]);
        cursor = (cursor + timedelta(days=32)).replace(day=1);
    }
    found: dict[str, list[list[object]]] = {};
    headers: dict[str, str] = {};
    client = httpx.Client(timeout=60.0);
    for month in months {
        name = f"news/{month}.json.gz";
        rows = read_cached(name);
        if rows is None and os.environ.get("BACKTEST_OFFLINE") == "1" {
            continue;
        }
        if rows is None {
            headers = headers or alpaca_headers();
            first = date.fromisoformat(month + "-01");
            after = (first + timedelta(days=32)).replace(day=1);
            seen: dict[int, list[object]] = {};
            for j in range(0, len(wanted), NEWS_SYMBOLS_PER_REQUEST) {
                part = wanted[j:j + NEWS_SYMBOLS_PER_REQUEST];
                token = "";
                while True {
                    params: dict[str, str | int] = {
                        "symbols": ",".join(part),
                        "start": first.isoformat() + "T00:00:00Z",
                        "end": after.isoformat() + "T00:00:00Z",
                        "limit": NEWS_PAGE,
                        "sort": "asc",
                        "include_content": "false"
                    };
                    if token {
                        params["page_token"] = token;
                    }
                    page = alpaca_get(client, "https://data.alpaca.markets/v1beta1/news", params, headers);
                    for row in page.get("news") or [] {
                        seen[int(row["id"])] = [row["created_at"], sorted(set(row.get("symbols") or []))];
                    }
                    token = page.get("next_page_token") or "";
                    if not token {
                        break;
                    }
                }
            }
            rows = sorted(seen.values(), key=lambda (r: list[object]) { str(r[0]); });
            write_cached(name, rows);
            say(f"news: {month}, {len(rows)} articles");
        }
        found[month] = rows;
    }
    return found;
}

glob _LAST_ALPACA: list[float] = [0.0];

"""One Alpaca GET at no more than ALPACA_PER_MINUTE, outside the quiet window, retried on
429, 5xx, and connection errors."""
def alpaca_get(client: httpx.Client, url: str, params: dict[str, str | int], headers: dict[str, str]) -> any {
    for attempt in range(8) {
        wait_for_alpaca();
        gap = 60.0 / ALPACA_PER_MINUTE - (time.monotonic() - _LAST_ALPACA[0]);
        if gap > 0 {
            time.sleep(gap);
        }
        _LAST_ALPACA[0] = time.monotonic();
        try {
            response = client.get(url, params=params, headers=headers);
        } except httpx.HTTPError {
            time.sleep(2.0 ** attempt);
            continue;
        }
        if response.status_code == 429 or response.status_code >= 500 {
            time.sleep(min(60.0, 2.0 ** attempt));
            continue;
        }
        response.raise_for_status();
        return response.json();
    }
    raise RuntimeError(f"Alpaca kept failing for {url}");
}

glob _LAST_SEC: list[float] = [0.0];

def sec_get(client: httpx.Client, url: str) -> any {
    for attempt in range(6) {
        gap = SEC_INTERVAL_S - (time.monotonic() - _LAST_SEC[0]);
        if gap > 0 {
            time.sleep(gap);
        }
        _LAST_SEC[0] = time.monotonic();
        try {
            response = client.get(url);
        } except httpx.HTTPError {
            time.sleep(2.0 ** attempt);
            continue;
        }
        if response.status_code == 404 {
            return None;
        }
        if response.status_code == 429 or response.status_code >= 500 {
            time.sleep(min(60.0, 2.0 ** (attempt + 2)));
            continue;
        }
        response.raise_for_status();
        return response.json();
    }
    raise RuntimeError(f"the SEC kept failing for {url}");
}

"""Filing dates of each company's 8-K Item 2.02 from `since` on, by padded CIK, from its
submissions file and the older files it lists."""
def earnings_dates(ciks: list[str], since: str) -> dict[str, list[str]] {
    found = read_cached("earnings.json.gz") or {};
    missing = [c for c in sorted(set(ciks)) if c and c not in found];
    if not missing {
        return found;
    }
    client = httpx.Client(timeout=60.0, headers={"User-Agent": sec_user_agent()}, follow_redirects=True);
    for (i, cik) in enumerate(missing) {
        dates: set[str] = set();
        parsed = sec_get(client, f"https://data.sec.gov/submissions/CIK{cik}.json");
        if parsed is not None {
            blocks = [parsed["filings"]["recent"]];
            for extra in parsed["filings"].get("files") or [] {
                if (extra.get("filingTo") or "9999") >= since {
                    more = sec_get(client, "https://data.sec.gov/submissions/" + extra["name"]);
                    if more is not None {
                        blocks.append(more);
                    }
                }
            }
            for block in blocks {
                for k in range(len(block["form"])) {
                    if block["form"][k] in ("8-K", "8-K/A") and "2.02" in (block["items"][k] or "") and block["filingDate"][k] >= since {
                        dates.add(block["filingDate"][k]);
                    }
                }
            }
        }
        found[cik] = sorted(dates);
        if (i + 1) % 50 == 0 or i + 1 == len(missing) {
            write_cached("earnings.json.gz", found);
            say(f"earnings: {i + 1} of {len(missing)} companies");
        }
    }
    return found;
}

"""Ticker to padded CIK for every company the SEC lists today."""
def sec_tickers -> dict[str, str] {
    found = read_cached("sec-tickers.json.gz");
    if found is None {
        client = httpx.Client(timeout=60.0, headers={"User-Agent": sec_user_agent()}, follow_redirects=True);
        response = client.get("https://www.sec.gov/files/company_tickers.json");
        response.raise_for_status();
        found = {alpaca_symbol(str(row["ticker"])): padded_cik(row["cik_str"]) for row in response.json().values()};
        write_cached("sec-tickers.json.gz", found);
    }
    return found;
}

"""The constituents table as it stood mid-year in each of `years`, as {symbol: {sector, cik}},
for members that have since left the index. Older revisions have no table id and name their
columns differently, so the first sortable wikitable is read and its columns matched loosely."""
def past_tables(years: list[int]) -> dict[str, dict[str, dict[str, str]]] {
    found = read_cached("past-tables.json.gz") or {};
    client = httpx.Client(timeout=60.0, headers={"User-Agent": USER_AGENT});
    changed = False;
    for year in years {
        key = str(year);
        if key in found {
            continue;
        }
        query = client.get(WIKI_API, params={"action": "query", "prop": "revisions", "titles": LIST_TITLE, "rvlimit": 1, "rvstart": f"{year}-07-01T00:00:00Z", "rvdir": "older", "rvprop": "ids|timestamp", "format": "json", "formatversion": 2}).json();
        revid = query["query"]["pages"][0]["revisions"][0]["revid"];
        html = client.get(WIKI_API, params={"action": "parse", "oldid": revid, "prop": "text", "format": "json", "formatversion": 2}).json()["parse"]["text"];
        if 'id="constituents"' in html {
            rows = table_records(html, "constituents");
        } else {
            html = re.sub(r'<table class="wikitable sortable', '<table id="harness-table" class="wikitable sortable', html, count=1);
            rows = table_records(html, "harness-table") if 'id="harness-table"' in html else [];
        }
        table: dict[str, dict[str, str]] = {};
        for row in rows {
            symbol = alpaca_symbol(column(row, ["Symbol", "Ticker symbol", "Ticker"]));
            if symbol {
                table[symbol] = {"sector": column(row, ["GICS Sector", "GICS sector"]), "cik": column(row, ["CIK", "Central Index Key"])};
            }
        }
        found[key] = table;
        changed = True;
        say(f"wikipedia: {year} revision {revid}, {len(table)} rows");
        time.sleep(2.0);
    }
    if changed {
        write_cached("past-tables.json.gz", found);
    }
    return found;
}

"""The first of `names` that `row` has, matched without case, spaces, or footnotes."""
def column(row: dict[str, str], names: list[str]) -> str {
    plain = {re.sub(r"[^a-z]", "", k.lower()): v for (k, v) in row.items()};
    for n in names {
        hit = plain.get(re.sub(r"[^a-z]", "", n.lower()));
        if hit {
            return hit.strip();
        }
    }
    return "";
}

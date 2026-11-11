"""Fill the backtest harness's cache (tests/backtest/data.jac) from the network, stage by stage.
Each stage resumes where a stopped one left off.

    set -a && source .env && set +a
    TRADING_AGENT_RUN_BACKTEST_FETCH=1 BACKTEST_CACHE=/path/to/cache \
        BACKTEST_STAGES=membership,bars,earnings,sectors,news jac run tests/backtest/fetch.jac
"""
import os;
import from tests.backtest.data {
    BARS_START,
    current_members,
    earnings_dates,
    membership,
    news,
    past_tables,
    bars,
    say,
    sec_tickers,
    sessions
}

glob RUN_ENV: str = "TRADING_AGENT_RUN_BACKTEST_FETCH";
# The harness decides from the first session of 2016 to the end of October 2026, and reads ten
# sessions past the end for the last hit-rate windows.
glob FIRST_DAY: str = "2016-01-04";
glob LAST_DAY: str = "2026-10-30";
glob BARS_END: str = "2026-11-10";

"""Every symbol that was a member on any day."""
def ever_members(members: dict[str, list[str]]) -> list[str] {
    return sorted({s for day in members.values() for s in day});
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        stages = [s.strip() for s in os.environ.get("BACKTEST_STAGES", "membership,bars,earnings,sectors,news").split(",") if s.strip()];
        days = [d for d in sessions(BARS_START, BARS_END) if FIRST_DAY <= d <= LAST_DAY];
        (members, gaps) = membership(days);
        symbols = ever_members(members);
        say(f"membership: {len(days)} sessions, {len(symbols)} symbols ever members, {len(gaps)} gaps");
        if "bars" in stages {
            series = bars(symbols + ["SPY"], BARS_END);
            say(f"bars: {len(series)} of {len(symbols) + 1} symbols have bars");
        }
        if "sectors" in stages {
            tables = past_tables(list(range(2016, 2026)));
            say(f"sectors: {sum(len(t) for t in tables.values())} rows over {len(tables)} years");
        }
        if "earnings" in stages {
            tables = past_tables(list(range(2016, 2026)));
            ciks = {m["symbol"]: m["cik"] for m in current_members()};
            for t in tables.values() {
                for (symbol, row) in t.items() {
                    if row.get("cik") and symbol not in ciks {
                        ciks[symbol] = row["cik"];
                    }
                }
            }
            listed = sec_tickers();
            padded = sorted({str(c).zfill(10) for c in ciks.values() if str(c).strip().isdigit()} | {listed[s] for s in symbols if s in listed});
            releases = earnings_dates(padded, "2015-12-01");
            say(f"earnings: {len(releases)} companies, {sum(len(v) for v in releases.values())} release dates");
        }
        if "news" in stages {
            articles = news(symbols, "2015-12-01", LAST_DAY);
            say(f"news: {sum(len(v) for v in articles.values())} articles over {len(articles)} months");
        }
    }
}

"""History-only collection for a replay (research/asof.jac): off for a live run, and in a replay
each bounded source drops whatever was published at or after the decision time. Recorded
responses only; no network and no real keys."""
import json;
import tempfile;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamp }
import from research.alpaca_news { article_counts, articles }
import from research.asof {
    as_of_day,
    as_of_end,
    as_of_time,
    decision_time,
    enter_as_of,
    filed_in_time,
    leave_as_of,
    open_month,
    reported_periods
}
import from research.briefs { FundamentalsInputs }
import from research.collector { Fetched, RawCache, RunBudget, SourceClient, TokenBucket, split_fresh }
import from research.finnhub { EpsSurprise, earnings_calendar, eps_surprises, recommendation_trends }
import from research.sec { Filing, filings, reduce_facts }
import from research.sources { DATASETS, SOURCES }
import from run.research { bound_surprises }
import from tests.fakes.source_server { FakeSource, serve_source }

glob ROOT: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures";
glob finnhub: FakeSource = serve_source(SOURCES["finnhub"].base_url_env, ROOT / "finnhub");
glob sec: FakeSource = serve_source(SOURCES["sec_data"].base_url_env, ROOT / "sec");
glob news: FakeSource = serve_source(SOURCES["alpaca_data"].base_url_env, ROOT / "alpaca");
glob AAPL: str = "0000320193";

def client(source: str, headers: dict[str, str]) -> SourceClient {
    return SourceClient(
        source=SOURCES[source],
        headers=headers,
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
}

def budget -> RunBudget {
    return RunBudget(limits={"finnhub": 50, "sec_data": 20, "alpaca_data": 50});
}

"""Run `check` in a replay of `day`, and always leave it."""
def replaying(day: str, check: Callable[[], None]) {
    enter_as_of(decision_time(day));
    try {
        check();
    } finally {
        leave_as_of();
    }
}

def stamped(published: str) -> Filing {
    return Filing(symbol="X", cik="1", form="8-K", accession="a", filed=published[:10], report_date="", accepted_at="", items=[], primary_document="", stamp=Stamp(source="t", dataset="t", source_url=f"u-{published}", published_at=published, fetched_at=""));
}

def surprise(period: str) -> EpsSurprise {
    return EpsSurprise(symbol="X", period=period, quarter=0, year=0, actual=1.0, estimate=1.0, surprise=0.0, surprise_percent=0.0, stamp=Stamp(source="t", dataset="t", source_url="", published_at=period, fetched_at=""));
}

def release_8k(filed: str) -> Filing {
    return Filing(symbol="X", cik="1", form="8-K", accession=filed, filed=filed, report_date="", accepted_at="", items=["2.02", "9.01"], primary_document="", stamp=Stamp(source="t", dataset="t", source_url="", published_at=filed, fetched_at=""));
}

test "the decision is 7:30 a.m. New York, in daylight and standard time" {
    assert decision_time("2026-10-15") == datetime(2026, 10, 15, 11, 30, tzinfo=timezone.utc);
    assert decision_time("2026-11-16") == datetime(2026, 11, 16, 12, 30, tzinfo=timezone.utc);
}

test "a live run has no decision time, so nothing is bounded" {
    assert as_of_time() is None and as_of_day() == "" and as_of_end() == "" and open_month() == "";
    assert filed_in_time("2099-01-01") and filed_in_time("");
    assert reported_periods(["2026-09-30"], []) == {"2026-09-30"};
    (kept, gaps) = split_fresh([stamped("2026-10-15T12:00:00+00:00")], DATASETS["sec.submissions"], datetime(2026, 10, 15, 13, 0, tzinfo=timezone.utc));
    assert len(kept) == 1 and gaps == [];
}

test "a replay ends news queries at the decision time, and a live run sends no end" {
    def check {
        news.reset();
        news.script = [(200, {}, json.dumps({"news": [], "next_page_token": None})), (200, {}, json.dumps({"news": []}))];
        data = client("alpaca_data", {"APCA-API-KEY-ID": "k", "APCA-API-SECRET-KEY": "s"});
        article_counts(["AAPL"], "2026-10-12", budget(), data);
        articles("AAPL", "2026-10-08", budget(), data, limit=5);
        assert [r.params.get("end") for r in news.requests] == ["2026-10-15T11:30:00Z", "2026-10-15T11:30:00Z"];
    }
    replaying("2026-10-15", check);
    news.reset();
    news.script = [(200, {}, json.dumps({"news": []}))];
    articles("AAPL", "2026-10-08", budget(), client("alpaca_data", {"APCA-API-KEY-ID": "k", "APCA-API-SECRET-KEY": "s"}), limit=5);
    assert "end" not in news.requests[0].params;
}

test "anything published at or after the decision time is dropped as stale, with a gap" {
    def check {
        items = [stamped("2026-10-15T11:29:59+00:00"), stamped("2026-10-15T11:30:00+00:00"), stamped("2026-10-16T09:00:00+00:00")];
        (kept, gaps) = split_fresh(items, DATASETS["sec.submissions"], as_of_time());
        assert [i.stamp.published_at for i in kept] == ["2026-10-15T11:29:59+00:00"];
        assert len(gaps) == 2 and all("after the replayed decision time" in g for g in gaps);
    }
    replaying("2026-10-15", check);
}

test "SEC filings dated on or after the replayed day are left out" {
    sec.reset();
    (_, live) = filings("AAPL", AAPL, budget(), client("sec_data", {"User-Agent": "test@example.edu"}));
    def check {
        sec.reset();
        (_, past) = filings("AAPL", AAPL, budget(), client("sec_data", {"User-Agent": "test@example.edu"}));
        assert past and all(f.filed < "2026-10-01" for f in past);
        assert len(past) == len([f for f in live if f.filed < "2026-10-01"]) < len(live);
    }
    replaying("2026-10-01", check);
}

test "XBRL facts filed on or after the replayed day are left out, so a later restatement does not replace the original" {
    facts = {"us-gaap": {"Assets": {"units": {"USD": [
        {"end": "2026-06-27", "val": 100.0, "filed": "2026-08-01", "accn": "a1", "form": "10-Q"},
        {"end": "2026-06-27", "val": 90.0, "filed": "2026-11-01", "accn": "a2", "form": "10-K"},
        {"end": "2026-09-26", "val": 120.0, "filed": "2026-10-31", "accn": "a3", "form": "10-K"}
    ]}}}};
    page = Fetched(source="sec_data", dataset="sec.companyfacts", source_url="https://data.sec.gov/x", fetched_at="2026-11-11T00:00:00+00:00", body="", from_cache=False);
    (live, _) = reduce_facts("X", AAPL, "X", facts, page);
    assert live is not None;
    now_assets = live.get("total_assets");
    assert now_assets is not None and now_assets.value == 120.0;
    def check {
        (past, _) = reduce_facts("X", AAPL, "X", facts, page);
        assert past is not None;
        assets = past.get("total_assets");
        assert assets is not None and (assets.value, assets.filed) == (100.0, "2026-08-01");
    }
    replaying("2026-10-15", check);
}

test "an earnings calendar keeps actual figures only for releases before the replayed day, and reads as of the decision" {
    def check {
        finnhub.reset();
        (releases, _) = earnings_calendar("2026-10-08", "2026-10-09", budget(), client("finnhub", {"X-Finnhub-Token": "t"}));
        pep = [r for r in releases if r.symbol == "PEP"][0];
        assert pep.eps_actual is None and pep.revenue_actual is None and pep.eps_estimate is not None;
        assert pep.stamp.published_at == "2026-10-08T11:29:59+00:00";
    }
    replaying("2026-10-08", check);
    def later {
        finnhub.reset();
        (releases, _) = earnings_calendar("2026-10-08", "2026-10-09", budget(), client("finnhub", {"X-Finnhub-Token": "t"}));
        assert [r for r in releases if r.symbol == "PEP"][0].eps_actual == 2.34;
    }
    replaying("2026-10-09", later);
    finnhub.reset();
    (live, _) = earnings_calendar("2026-10-08", "2026-10-09", budget(), client("finnhub", {"X-Finnhub-Token": "t"}));
    assert all(r.stamp.published_at == r.stamp.fetched_at for r in live);
}

test "the decision's own month of analyst counts is left out" {
    def check {
        finnhub.reset();
        found = recommendation_trends("AAPL", budget(), client("finnhub", {"X-Finnhub-Token": "t"}));
        assert [t.period for t in found] == ["2026-08-01", "2026-07-01", "2026-06-01"];
    }
    replaying("2026-09-14", check);
}

test "an EPS quarter shows only once an earnings release after it was filed before the decision" {
    def check {
        assert reported_periods(["2026-06-30", "2026-09-30"], ["2026-07-30", "2026-10-30"]) == {"2026-06-30"};
        assert reported_periods(["2026-06-30"], ["2026-10-15"]) == set();
        funda = FundamentalsInputs(surprises=[surprise("2026-09-30"), surprise("2026-06-30")]);
        bound_surprises(funda, [release_8k("2026-07-30"), release_8k("2026-10-30")]);
        assert [s.period for s in funda.surprises] == ["2026-06-30"];
        assert any("2026-09-30" in g for g in funda.gaps);
        unknown = FundamentalsInputs(surprises=[surprise("2026-06-30")]);
        bound_surprises(unknown, None);
        assert unknown.surprises == [] and unknown.gaps;
    }
    replaying("2026-10-15", check);
    finnhub.reset();
    live = FundamentalsInputs(surprises=eps_surprises("AAPL", budget(), client("finnhub", {"X-Finnhub-Token": "t"})));
    bound_surprises(live, None);
    assert len(live.surprises) == 4 and live.gaps == [];
}

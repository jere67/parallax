"""The collection pass in a replay (run/research.jac with research/asof.jac): EPS quarters are
kept only once an earnings release covered them before the decision. Recorded responses only;
no network and no real keys."""
import tempfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from models.research { Stamp }
import from research.asof { decision_time, enter_as_of, leave_as_of }
import from research.briefs { FundamentalsInputs }
import from research.collector { RawCache, RunBudget, SourceClient, TokenBucket }
import from research.finnhub { EpsSurprise, eps_surprises }
import from research.sec { Filing }
import from research.sources { SOURCES }
import from run.research { bound_surprises }
import from tests.fakes.source_server { FakeSource, serve_source }

glob finnhub: FakeSource = serve_source(SOURCES["finnhub"].base_url_env, Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "finnhub");

def surprise(period: str) -> EpsSurprise {
    return EpsSurprise(symbol="X", period=period, quarter=0, year=0, actual=1.0, estimate=1.0, surprise=0.0, surprise_percent=0.0, stamp=Stamp(source="t", dataset="t", source_url="", published_at=period, fetched_at=""));
}

def release_8k(filed: str) -> Filing {
    return Filing(symbol="X", cik="1", form="8-K", accession=filed, filed=filed, report_date="", accepted_at="", items=["2.02", "9.01"], primary_document="", stamp=Stamp(source="t", dataset="t", source_url="", published_at=filed, fetched_at=""));
}

test "a replay keeps an EPS quarter only once an earnings release covered it, and drops all of them without filings" {
    enter_as_of(decision_time("2026-10-15"));
    try {
        funda = FundamentalsInputs(surprises=[surprise("2026-09-30"), surprise("2026-06-30")]);
        bound_surprises(funda, [release_8k("2026-07-30"), release_8k("2026-10-30")]);
        assert [s.period for s in funda.surprises] == ["2026-06-30"];
        assert any("2026-09-30" in g for g in funda.gaps);
        unknown = FundamentalsInputs(surprises=[surprise("2026-06-30")]);
        bound_surprises(unknown, None);
        assert unknown.surprises == [] and unknown.gaps;
    } finally {
        leave_as_of();
    }
}

test "a live run keeps every EPS quarter" {
    finnhub.reset();
    client = SourceClient(
        source=SOURCES["finnhub"],
        headers={"X-Finnhub-Token": "t"},
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100),
        backoff_s=0.0
    );
    live = FundamentalsInputs(surprises=eps_surprises("AAPL", RunBudget(limits={"finnhub": 50}), client));
    bound_surprises(live, None);
    assert len(live.surprises) == 4 and live.gaps == [];
}

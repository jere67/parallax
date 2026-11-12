"""SEC company facts reduced to a company's figures and period tables."""
import os;
import tempfile;
import from jaclang.data.storage.storage { Storage }
import from market.companies { company_facts, company_record, figures_of, filings_of, wants_facts }
import from research.collector { RawCache, RunBudget, SourceClient, TokenBucket }
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource }

def fact(start: str, end: str, value: float, filed: str = "2026-02-01", form: str = "10-K") -> dict[str, any] {
    row: dict[str, any] = {"end": end, "val": value, "filed": filed, "form": form, "accn": "1"};
    if start {
        row["start"] = start;
    }
    return row;
}

def usd(rows: list[dict[str, any]]) -> dict[str, any] {
    return {"units": {"USD": rows}};
}

"""A year of four quarters: 90, 100, 110, and a fourth known only as the 400 year less the 300 of
nine months, which is how a 10-Q reports it."""
def facts_of_a_year -> dict[str, dict[str, any]] {
    return {
        "us-gaap": {
            "Revenues": usd([
                fact("2024-01-01", "2024-12-31", 300.0, "2025-02-01"),
                fact("2024-10-01", "2024-12-31", 80.0, "2025-02-01", "10-Q"),
                fact("2025-01-01", "2025-03-31", 90.0, "2025-05-01", "10-Q"),
                fact("2025-04-01", "2025-06-30", 100.0, "2025-08-01", "10-Q"),
                fact("2025-07-01", "2025-09-30", 110.0, "2025-11-01", "10-Q"),
                fact("2025-01-01", "2025-09-30", 300.0, "2025-11-01", "10-Q"),
                fact("2025-01-01", "2025-12-31", 400.0)
            ]),
            "NetIncomeLoss": usd([fact("2025-01-01", "2025-12-31", -40.0)]),
            "NetCashProvidedByUsedInOperatingActivities": usd([fact("2025-01-01", "2025-12-31", 70.0)]),
            "PaymentsToAcquirePropertyPlantAndEquipment": usd([fact("2025-01-01", "2025-12-31", 20.0)]),
            "Assets": usd([fact("", "2025-12-31", 900.0)]),
            "StockholdersEquity": usd([fact("", "2025-12-31", 300.0)])
        }
    };
}

test "the year's figures come out of the facts" {
    (values, annual, quarterly, end, filed) = figures_of(facts_of_a_year(), "2026-03-01");
    assert end == "2025-12-31";
    assert filed == "2026-02-01";
    assert values["revenue_fy"] == 400.0;
    assert values["net_income_fy"] == -40.0;
    assert values["free_cash_flow_ttm"] == 50.0;
    assert [p.label for p in annual] == ["FY2024", "FY2025"];
    assert annual[-1].values["free_cash_flow"] == 50.0;
    assert annual[-1].values["total_assets"] == 900.0;
}

test "a fourth quarter is the year less the other three" {
    (_, _, quarterly, _, _) = figures_of(facts_of_a_year(), "2026-03-01");
    fourth = [p for p in quarterly if p.end == "2025-12-31"];
    assert len(fourth) == 1;
    assert fourth[0].values["revenue"] == 100.0;
}

test "figures long out of date are dropped" {
    (values, annual, quarterly, end, _) = figures_of(facts_of_a_year(), "2028-06-01");
    assert values == {} and annual == [] and quarterly == [] and end == "";
}

test "a filer on another taxonomy has no figures rather than wrong ones" {
    (values, annual, _, end, _) = figures_of({"ifrs-full": {"Revenue": usd([fact("2025-01-01", "2025-12-31", 1.0)])}}, "2026-03-01");
    assert values == {} or "revenue_ttm" not in values;
    assert annual == [] and end == "";
}

def submissions_of(forms: list[str], filed: list[str]) -> dict[str, any] {
    size = len(forms);
    return {
        "name": "Acme",
        "sic": "3571",
        "sicDescription": "ELECTRONIC COMPUTERS",
        "fiscalYearEnd": "1231",
        "stateOfIncorporation": "DE",
        "addresses": {"business": {"city": "Ann Arbor", "stateOrCountry": "MI"}},
        "filings": {"recent": {
            "form": forms,
            "filingDate": filed,
            "reportDate": filed,
            "accessionNumber": [f"0000-00-{i:06d}" for i in range(size)],
            "primaryDocument": [f"doc{i}.htm" for i in range(size)]
        }}
    };
}

test "only the forms a reader wants are shown, and the newest report is found" {
    found = submissions_of(["4", "10-Q", "8-K", "10-K"], ["2026-05-02", "2026-05-01", "2026-04-01", "2026-02-01"]);
    (filings, report_filed) = filings_of("0000000001", found);
    assert [f.form for f in filings] == ["10-Q", "8-K", "10-K"];
    assert report_filed == "2026-05-01";
    assert "sec.gov" in filings[0].url and "doc1.htm" in filings[0].url;
}

test "facts are asked for only when a newer report is out, and the old ones stay meanwhile" {
    first = submissions_of(["10-K"], ["2026-02-01"]);
    assert wants_facts(first, None);
    record = company_record("0000000001", first, {"facts": facts_of_a_year()}, "2026-03-01");
    assert record.values["revenue_fy"] == 400.0;
    assert not wants_facts(first, record);
    later = company_record("0000000001", first, None, "2026-03-02", record);
    assert later.values == record.values and later.checked == "2026-03-02";
    newer = submissions_of(["10-Q", "10-K"], ["2026-05-01", "2026-02-01"]);
    assert wants_facts(newer, record);
}

test "a filer SEC answers with an empty object has no facts, as a 404 does, rather than failing" {
    fake = FakeSource();
    env = SOURCES["sec_data"].base_url_env;
    before = os.environ.get(env);
    os.environ[env] = fake.start();
    try {
        # SEC answers John Hancock Income Securities Trust (JHS), a closed-end fund, with 200 and {}.
        fake.script.append((200, {"Content-Type": "application/json"}, "{}"));
        client = SourceClient(
            source=SOURCES["sec_data"],
            cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
            bucket=TokenBucket(per_minute=60000, burst=100),
            backoff_s=0.0
        );
        assert company_facts("0000759866", RunBudget(limits={"sec_data": 5}), client) is None;
    } finally {
        fake.stop();
        if before is None {
            os.environ.pop(env, None);
        } else {
            os.environ[env] = before;
        }
    }
}

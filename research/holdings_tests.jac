"""Bulk 13F contracts: binary replay, amended positions, conservative joins and lag.
The TSV reconstruction's provenance and synthetic cases are documented with the fixture."""
import io;
import json;
import os;
import tempfile;
import zipfile;
import from pathlib { Path }
import from jaclang.data.storage.storage { Storage }
import from research.briefs { FundamentalsInputs, fundamentals_brief }
import from research.collector { Fetched, RawCache, RunBudget, SourceClient, TokenBucket, request_key }
import from research.holdings {
    Archive, INDEX_PATH, archives, filing_deadline, institutional_holdings,
    join_holdings, normalized_name, previous_quarter, reduce_archive
}
import from research.sources { SOURCES }
import from tests.fakes.source_server { FakeSource }

glob FIXTURES: Path = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "holdings";
glob CURRENT_PATH: str = "/files/datastandardsinnovation/data/form-13f-data-sets/01jun2026-31aug2026_form13f.zip";
glob PRIOR_PATH: str = "/files/structureddata/data/form-13f-data-sets/01mar2026-31may2026_form13f.zip";
glob LISTING: str = f'<a href="{CURRENT_PATH}">June July August 2026</a><a href="{PRIOR_PATH}">March April May 2026</a>';
glob NAMES: dict[str, str] = {"AAPL": "Apple Inc.", "MSFT": "Microsoft Corporation", "GOOG": "Alphabet Inc.", "GOOGL": "Alphabet Inc.", "MISS": "Missing Corporation"};

def fixture_zip -> bytes {
    buffer = io.BytesIO();
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z {
        for table in ["SUBMISSION", "COVERPAGE", "INFOTABLE"] {
            z.writestr(table + ".tsv", (FIXTURES / (table + ".tsv")).read_bytes());
        }
    }
    return buffer.getvalue();
}

"""A second quarter with two managers and a restatement followed by an addition."""
def current_zip(extra: str = "", quarter: str = "30-JUN-2026") -> bytes {
    buffer = io.BytesIO();
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z {
        z.writestr("SUBMISSION.tsv", "ACCESSION_NUMBER\tCIK\tFILING_DATE\tPERIODOFREPORT\tSUBMISSIONTYPE\n"
            + f"a\t1\t10-AUG-2026\t{quarter}\t13F-HR\n"
            + f"b\t1\t11-AUG-2026\t{quarter}\t13F-HR/A\n"
            + f"c\t1\t12-AUG-2026\t{quarter}\t13F-HR/A\n"
            + f"d\t2\t12-AUG-2026\t{quarter}\t13F-HR\n"
            + f"e\t3\t12-AUG-2026\t{quarter}\t13F-HR/A\n"
            + "old\t4\t13-AUG-2026\t31-MAR-2026\t13F-HR\n");
        z.writestr("COVERPAGE.tsv", "ACCESSION_NUMBER\tAMENDMENTTYPE\na\t\nb\tRESTATEMENT\nc\tNEW HOLDINGS\nd\t\ne\tUNKNOWN\nold\t\n");
        z.writestr("INFOTABLE.tsv", "ACCESSION_NUMBER\tCUSIP\tNAMEOFISSUER\tTITLEOFCLASS\tSSHPRNAMT\tSSHPRNAMTTYPE\tPUTCALL\tVALUE\tOTHERMANAGER\n"
            + "a\t037833100\tAPPLE INC\tCOM\t100\tSH\t\t20000\t\n"
            + "b\t037833100\tAPPLE INC\tCOM\t120\tSH\t\t24000\t\n"
            + "b\t037833100\tAPPLE INC\tCOM\t30\tSH\t\t6000\t\n"
            + "c\t037833100\tAPPLE INC\tCOM\t10\tSH\t\t2000\t\n"
            + "d\t037833100\tAPPLE INC\tCOM\t40\tSH\t\t8000\t\n"
            + "e\t037833100\tAPPLE INC\tCOM\t900\tSH\t\t180000\t\n"
            + "old\t037833100\tAPPLE INC\tCOM\t7000\tSH\t\t1400000\t\n"
            + "d\t037833100\tAPPLE INC\tCOM\t100000\tSH\tCall\t500\t\n"
            + "d\t037833100\tAPPLE INC\tNOTE\t500\tPRN\t\t500\t\n"
            + "d\t037833100\tAPPLE INC\tPFD\t500\tSH\t\t500\t\n"
            + "d\t037833100\tAPPLE INC\tPREFERRED SHARES\t500\tSH\t\t500\t\n"
            + "d\t037833100\tAPPLE INC\tCOM\t30\tSH\t\t6000\t1\n"
            + "d\t594918104\tMICROSOFT CORP\tCOM\t20\tSH\t\t6000\t\n"
            + extra);
    }
    return buffer.getvalue();
}

def fetched(body: str) -> Fetched {
    return Fetched(source="sec_archives", dataset="sec.13f", source_url="https://www.sec.gov" + CURRENT_PATH, fetched_at="2026-10-23T12:00:00+00:00", body=body, from_cache=False);
}

def setup(prior: bool = True) -> tuple[FakeSource, SourceClient, RunBudget] {
    fake = FakeSource();
    os.environ["SEC_ARCHIVES_URL"] = fake.start();
    fake.recordings[request_key(INDEX_PATH, {})] = LISTING;
    fake.recordings[request_key(CURRENT_PATH, {})] = current_zip();
    if prior {
        fake.recordings[request_key(PRIOR_PATH, {})] = fixture_zip();
    }
    return (fake, SourceClient(
        source=SOURCES["sec_archives"], headers={"User-Agent": "parallax-tests test@example.edu"},
        cache=RawCache(storage=store(base_path=tempfile.mkdtemp()) as Storage),
        bucket=TokenBucket(per_minute=60000, burst=100), backoff_s=0.0, max_retries=0
    ), RunBudget(limits={"sec_archives": 20}));
}

test "modern filing windows select holdings quarters without selecting future windows" {
    a = archives(LISTING, "2026-10-23");
    assert [(x.quarter, x.end) for x in a] == [("2026-06-30", "2026-08-31"), ("2026-03-31", "2026-05-31")];
    assert [x.quarter for x in archives(LISTING, "2026-08-31")] == ["2026-03-31"];
    assert archives('<a href="https://evil.example' + CURRENT_PATH + '">fake</a>', "2026-10-23") == [];
    assert previous_quarter("2026-02-28") == "2025-12-31";
    assert filing_deadline("2026-06-30") == "2026-08-14";
    assert filing_deadline("2025-12-31") == "2026-02-17";
}

test "the recorded issuer rows retain dollar units and leading CUSIP zeros" {
    parsed = json.loads(reduce_archive(fixture_zip(), "2026-03-31"));
    apple = parsed["totals"]["037833100"];
    assert (apple["shares"], apple["value_usd"], apple["managers"]) == (322470, 81839757, 1);
    assert parsed["totals"]["594918104"]["value_usd"] == 53129038;
    assert len(parsed["totals"]) == 4;
}

test "restatements replace originals and additions extend one manager without double counting" {
    parsed = json.loads(reduce_archive(current_zip(), "2026-06-30"));
    apple = parsed["totals"]["037833100"];
    assert (apple["shares"], apple["value_usd"], apple["managers"]) == (230, 46000, 2);
    assert len(parsed["totals"]) == 2;
    assert any("CIK 3" in g for g in parsed["gaps"]);
    assert any("shared-manager" in g for g in parsed["gaps"]);
}

test "name joins report missing names and ambiguous share classes instead of zeros" {
    archive = Archive(path=PRIOR_PATH, end="2026-05-31", quarter="2026-03-31");
    batch = join_holdings(NAMES, fetched(reduce_archive(fixture_zip(), archive.quarter)), archive);
    assert set(batch.values) == {"AAPL", "MSFT"};
    assert batch.values["AAPL"].cusip == "037833100";
    assert "02079K305" in batch.gaps["GOOG"][0] and "02079K107" in batch.gaps["GOOG"][0];
    assert "CUSIPs: none" in batch.gaps["MISS"][0];
    assert normalized_name("Microsoft Corporation") == normalized_name("MICROSOFT CORP");
    assert normalized_name("Acme Holdings") != normalized_name("Acme");
}

test "binary replay computes sourced deltas and reuses one quarterly download across run dates" {
    (fake, client, budget) = setup();
    try {
        batch = institutional_holdings(NAMES, "2026-10-23", budget, client);
        assert fake.misses == [];
        h = batch.values["AAPL"];
        assert (h.shares, h.value_usd, h.managers) == (230, 46000, 2);
        assert (h.shares_change, h.value_change_usd, h.managers_change) == (-322240, -81793757, 1);
        assert h.prior_quarter == "2026-03-31" and h.filing_deadline == "2026-08-14";
        assert h.prior_source_url.endswith(PRIOR_PATH) and h.stamp.source_url.endswith(CURRENT_PATH);
        assert h.stamp.published_at == "2026-08-31";
        again = institutional_holdings({"MSFT": NAMES["MSFT"]}, "2026-10-24", budget, client);
        assert again.values["MSFT"].shares == 20;
        assert budget.spent == {"sec_archives": 3};
        assert len(fake.requests) == 3;
        assert fake.requests[1].headers["User-Agent"].startswith("parallax-tests");
    } finally {
        fake.stop();
    }
}

test "a failed prior quarter preserves current holdings and leaves deltas unknown" {
    (fake, client, budget) = setup(prior=False);
    try {
        batch = institutional_holdings(NAMES, "2026-10-23", budget, client);
        assert batch.values["AAPL"].shares == 230;
        assert batch.values["AAPL"].shares_change is None;
        assert any("prior quarter 2026-03-31 unavailable" in g for g in batch.gaps["AAPL"]);
    } finally {
        fake.stop();
    }
}

test "a rejected archive is not cached and can recover on the next attempt" {
    (fake, client, budget) = setup();
    fake.recordings[request_key(CURRENT_PATH, {})] = "<html>Access denied</html>";
    try {
        failed = institutional_holdings(NAMES, "2026-10-23", budget, client);
        assert failed.values == {} and any("BadZipFile" in g for g in failed.gaps["AAPL"]);
        fake.recordings[request_key(CURRENT_PATH, {})] = current_zip();
        assert institutional_holdings(NAMES, "2026-10-23", budget, client).values["AAPL"].shares == 230;
        assert len([r for r in fake.requests if r.path == CURRENT_PATH]) == 2;
    } finally {
        fake.stop();
    }
}

test "a changed TSV schema and nonfinite amounts fail before caching" {
    with testraises(ValueError) {
        reduce_archive(current_zip(quarter="31-DEC-2025"), "2026-06-30");
    }
    with testraises(ValueError) {
        reduce_archive(current_zip(extra="d\t037833100\tAPPLE INC\tCOM\tnan\tSH\t\t50\t\n"), "2026-06-30");
    }
    buffer = io.BytesIO();
    with zipfile.ZipFile(buffer, "w") as z {
        z.writestr("SUBMISSION.tsv", "WRONG\n1\n");
    }
    with testraises(ValueError, `match="required columns") {
        reduce_archive(buffer.getvalue(), "2026-06-30");
    }
}

test "the brief exposes the holdings age and both sources for the Flow specialist" {
    (fake, client, budget) = setup();
    try {
        batch = institutional_holdings(NAMES, "2026-10-23", budget, client);
        brief = fundamentals_brief("AAPL", "2026-10-23", FundamentalsInputs(holdings=batch.values["AAPL"], gaps=batch.gaps["AAPL"]));
        rendered = brief.render();
        assert "115 calendar days old" in rendered;
        assert "filing deadline 2026-08-14" in rendered;
        assert "shares -322,240" in rendered and "managers +1" in rendered;
        assert "not net buying" in rendered;
        assert len([u for u in brief.published_by_url() if u.endswith(".zip")]) == 2;
        assert any("confidential holdings" in g for g in brief.gaps);
    } finally {
        fake.stop();
    }
}

test "a stale listing yields a freshness gap without downloading an old archive" {
    (fake, client, budget) = setup();
    try {
        batch = institutional_holdings(NAMES, "2027-10-23", budget, client);
        assert batch.values == {};
        assert any("freshness limit" in g for g in batch.gaps["AAPL"]);
        assert len(fake.requests) == 1;
    } finally {
        fake.stop();
    }
}

test "pre-2023 filings convert thousands of dollars while modern filings remain dollars" {
    buffer = io.BytesIO();
    with zipfile.ZipFile(io.BytesIO(current_zip(quarter="30-JUN-2022"))) as old {
        with zipfile.ZipFile(buffer, "w") as changed {
            for name in old.namelist() {
                text = old.read(name).decode();
                if name == "SUBMISSION.tsv" {
                    text = text.replace("AUG-2026", "AUG-2022");
                }
                changed.writestr(name, text);
            }
        }
    }
    parsed = json.loads(reduce_archive(buffer.getvalue(), "2022-06-30"));
    assert parsed["totals"]["037833100"]["value_usd"] == 46000000;
    assert parsed["totals"]["037833100"]["shares"] == 230;
}

test "issuer aliases connecting different tickers are an ambiguous join" {
    body = json.loads(reduce_archive(fixture_zip(), "2026-03-31"));
    body["totals"]["037833100"]["names"].append("Microsoft Corp");
    batch = join_holdings(NAMES, fetched(json.dumps(body)), Archive(path=PRIOR_PATH, end="2026-05-31", quarter="2026-03-31"));
    assert "AAPL" not in batch.values and "MSFT" not in batch.values;
    assert any("no unambiguous" in g for g in batch.gaps["AAPL"]);
}

"""What the sweeps leave on disk comes back the same, and a broken file costs only itself."""
import json;
import tempfile;
import from pathlib { Path }
import from market.analysts { AnalystRecord, RatingPoint, Surprise }
import from market.companies { CompanyProfile, CompanyRecord, FilingLink, Period }
import from market.listings { Listing }
import from market.prices { PriceStats, Quote }
import from market.state { CompanySummary, EarningsDates, MarketState, jsonable, summary_of }

test "every domain survives a trip through the disk" {
    with tempfile.TemporaryDirectory() as folder {
        state = MarketState(base=Path(folder));
        state.loaded = True;
        state.listings = {"X": Listing(symbol="X", name="X Corp", cik="1", exchange="NYSE", kind="common", sp500=True)};
        state.quotes = {"X": Quote(symbol="X", day="2026-11-05", price=10.0, ext_price=10.5)};
        state.stats = {"X": PriceStats(symbol="X", day="2026-11-05", anchors={"1y": 8.0}, beta=1.2)};
        state.companies = {"1": CompanySummary(cik="1", checked="2026-11-05", values={"revenue_ttm": 5.0})};
        state.analysts = {"X": AnalystRecord(symbol="X", checked="2026-11-05", score=0.5, trend=[RatingPoint(period="2026-11-01", score=0.5, analysts=9)], surprises=[Surprise(period="2026-09-30", surprise_pct=1.5)])};
        state.earnings = {"X": EarningsDates(last_day="2026-10-30", next_day="2026-12-01", next_hour="amc")};
        state.meta = {"quotes_at": "2026-11-05T21:00:00+00:00"};
        for name in ["listings", "quotes", "stats", "companies", "analysts", "earnings", "meta"] {
            state.save(name);
        }
        again = MarketState(base=Path(folder));
        again.load();
        assert again.listings["X"].sp500;
        assert again.quotes["X"].ext_price == 10.5;
        assert again.stats["X"].anchors == {"1y": 8.0};
        assert again.companies["1"].values == {"revenue_ttm": 5.0};
        assert again.analysts["X"].trend[0].analysts == 9;
        assert again.analysts["X"].surprises[0].surprise_pct == 1.5;
        assert again.earnings["X"].next_hour == "amc";
        assert again.meta["quotes_at"].startswith("2026-11-05");
    }
}

test "a company's record lives in its own file" {
    with tempfile.TemporaryDirectory() as folder {
        state = MarketState(base=Path(folder));
        record = CompanyRecord(
            cik="1",
            checked="2026-11-05",
            profile=CompanyProfile(name="X Corp", sic=3571),
            filings=[FilingLink(form="10-K", filed="2026-02-01", report_date="2025-12-31", url="https://www.sec.gov/x")],
            annual=[Period(end="2025-12-31", label="FY2025", values={"revenue": 5.0})],
            values={"revenue_ttm": 5.0}
        );
        state.save_company(record);
        found: any = state.company("1");
        assert found.profile.sic == 3571;
        assert found.filings[0].form == "10-K";
        assert found.annual[0].values == {"revenue": 5.0};
        assert state.company("2") is None;
        assert summary_of(found).values == {"revenue_ttm": 5.0};
    }
}

test "a broken file reads as empty, and the rest still loads" {
    with tempfile.TemporaryDirectory() as folder {
        base = Path(folder);
        (base / "quotes.json").write_text("{not json");
        (base / "meta.json").write_text(json.dumps({"sessions": "x"}));
        state = MarketState(base=base);
        state.load();
        assert state.quotes == {} and state.meta == {"sessions": "x"};
    }
}

test "a demo state never touches the disk" {
    with tempfile.TemporaryDirectory() as folder {
        state = MarketState(base=Path(folder), demo=True);
        state.save("quotes");
        state.save_company(CompanyRecord(cik="1", checked="2026-11-05"));
        assert list(Path(folder).iterdir()) == [];
        kept: any = state.company("1");
        assert kept.cik == "1";
    }
}

test "a write replaces the old file and leaves no temporary behind" {
    with tempfile.TemporaryDirectory() as folder {
        state = MarketState(base=Path(folder));
        state.save("meta");
        state.meta = {"a": "b"};
        state.save("meta");
        assert [p.name for p in Path(folder).iterdir()] == ["meta.json"];
    }
}

test "plain JSON comes out however deep the objs are" {
    assert jsonable({"a": [EarningsDates(last_day="x")]}) == {"a": [{"last_day": "x", "next_day": "", "next_hour": ""}]};
}

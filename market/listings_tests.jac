"""Which listings count as stocks, how their names read, and what a sector code means."""
import from market.demo { demo_stamp }
import from market.listings { ListedTicker, build_listings, company_name, is_fund, is_special_line, is_stock }
import from market.sectors { sector_of }
import from research.alpaca { Asset }
import from research.wikipedia { Constituent }

def asset(symbol: str, name: str, exchange: str = "NASDAQ", tradable: bool = True) -> Asset {
    return Asset(stamp=demo_stamp("2026-11-05"), symbol=symbol, name=name, exchange=exchange, tradable=tradable, fractionable=True, shortable=True, easy_to_borrow=True);
}

def ticker(symbol: str, cik: str = "1") -> ListedTicker {
    return ListedTicker(symbol=symbol, cik=cik, name=symbol, exchange="Nasdaq");
}

test "warrants units rights preferreds and notes are not stocks" {
    for name in ["Acme Corp. Warrant", "Acme Acquisition Units", "Acme Rights", "Acme 5.25% Preferred Stock", "Acme Senior Notes due 2030"] {
        assert not is_stock(name), name;
    }
    assert is_stock("Apple Inc. Common Stock");
    assert is_stock("Taiwan Semiconductor Manufacturing Company Ltd. American Depositary Shares");
}

test "funds, notes, and preferred depositary shares that name neither are not stocks" {
    for name in [
        "First Citizens BancShares, Inc. Depositary Shares, Each Representing a 1/40th Interest in a Share",
        "Alerian MLP Index ETNs due January 28, 2044",
        "ProShares Ultra Gold",
        "iShares Silver Trust",
        "Invesco CurrencyShares Euro Currency Trust",
        "MicroSectors FANG+ Index -3X Inverse Leveraged",
        "UBS AG ETRACS Gold Shares Covered Call",
        "Sprott Physical Copper Trust",
        "Morgan Stanley Bitcoin Trust",
        "Empire State Realty OP, L.P. Series 250"
    ] {
        assert not is_stock(name), name;
    }
    for name in ["POSCO Holdings Inc. American Depositary Shares (each representing 1/4th of a share)", "Colliers International Group Inc. Subordinate Voting Shares", "Essex Property Trust, Inc.", "Strategy Inc"] {
        assert is_stock(name), name;
    }
}

test "a Nasdaq symbol's fifth letter marks its other lines, and only on Nasdaq" {
    for symbol in ["FCNCP", "PSNYW", "ACMER", "ACMEU", "ACMEZ"] {
        assert is_special_line(symbol, "NASDAQ"), symbol;
    }
    for symbol in ["GOOGL", "FORTY", "RYAAY", "LBTYK", "AAPL"] {
        assert not is_special_line(symbol, "NASDAQ"), symbol;
    }
    assert not is_special_line("ABCDP", "NYSE");
}

test "a filer's code tells a fund from a stock once it is known" {
    assert is_fund("iShares Gold Trust", 6221) and is_fund("US Commodity Index", 6221);
    assert not is_fund("Uranium Royalty Corp.", 6221);
    assert is_fund("BlackRock Income Trust Inc.", 0);
    assert not is_fund("Golub Capital BDC, Inc.", 0);
    assert not is_fund("Essex Property Trust, Inc.", 6798);
    assert not is_fund("Mesa Royalty Trust", None);
}

test "a company name drops the share line and leaves capitals out" {
    assert company_name("Apple Inc. Common Stock") == "Apple Inc.";
    assert company_name("ACME WIDGETS") == "Acme Widgets";
}

test "two share classes read as one company" {
    assert company_name("Alphabet Inc. Class A Common Stock") == company_name("Alphabet Inc. Class C Capital Stock");
}

test "the universe is what SEC lists and Alpaca can trade" {
    assets = {
        "AAPL": asset("AAPL", "Apple Inc. Common Stock"),
        "TSM": asset("TSM", "Taiwan Semiconductor American Depositary Shares", exchange="NYSE"),
        "OLD": asset("OLD", "Old Corp Common Stock", tradable=False),
        "OTC": asset("OTC", "Off Exchange Inc", exchange="OTC"),
        "NOSEC": asset("NOSEC", "Not In Sec Inc"),
        "ACMEW": asset("ACMEW", "Acme Corp. Warrant"),
        "ACMEP": asset("ACMEP", "Acme Corp. Depositary Shares")
    };
    tickers = {s: ticker(s) for s in ["AAPL", "TSM", "OLD", "OTC", "ACMEW", "ACMEP"]};
    member = Constituent(stamp=demo_stamp("2026-11-05"), symbol="AAPL", name="Apple", sector="Information Technology", sub_industry="Hardware", cik="1", date_added="");
    found = build_listings(tickers, assets, [member]);
    assert sorted(found) == ["AAPL", "TSM"];
    assert found["AAPL"].sp500 and found["AAPL"].name == "Apple Inc." and found["AAPL"].sector == "Information Technology";
    assert found["TSM"].kind == "adr" and not found["TSM"].sp500 and found["TSM"].exchange == "NYSE";
}

test "a sector code maps to a sector, and an unknown one to none" {
    assert sector_of(3571) == "Information Technology";
    assert sector_of(6021) == "Financials";
    assert sector_of(None) == "";
    assert sector_of(0) == "";
}

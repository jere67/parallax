"""The screener's filters, sort, paging, and peers. The filters arrive from anyone on the web."""
import from market.query { MAX_LIMIT, RowFilter, as_count, as_flag, as_list, as_text, peers_of, read_filters, run_query }

def row(symbol: str, cap: float | None = None, sector: str = "Energy", industry: str = "Oil", name: str = "") -> dict[str, float | str | None] {
    return {"symbol": symbol, "name": name or f"{symbol} Corp", "market_cap": cap, "sector": sector, "industry": industry};
}

glob ROWS: list[dict[str, float | str | None]] = [row("A", 10.0), row("B", 30.0), row("C", None), row("D", 20.0, sector="Utilities"), row("E", 30.0)];

def symbols_of(rows: list[dict[str, float | str | None]]) -> list[str] {
    return [str(r["symbol"]) for r in rows];
}

test "only known fields and usable bounds are read" {
    sent: list[any] = [
            {"field": "market_cap", "min": 5, "max": "lots"},
            {"field": "secret", "min": 1},
            {"field": "sector", "one_of": ["Energy", 3]},
            {"field": "market_cap"},
            {"field": "market_cap", "min": float("inf")},
            {"field": "market_cap", "min": True},
            "not a filter"
    ];
    found = read_filters(sent, {"market_cap", "sector"});
    assert len(found) == 2;
    assert found[0].low == 5.0 and found[0].high is None;
    assert found[1].one_of == ["Energy", "3"];
    assert len(read_filters([{"field": "sector", "one_of": ["x"]}] * 500, {"sector"})) == 40;
}

test "an argument of the wrong type falls back, including a default the server sends as text" {
    assert as_list("[]") == [] and as_list(5) == [] and as_list(["a"]) == ["a"];
    assert as_text(None) == "" and as_text(7) == "" and as_text("x") == "x";
    assert as_count("0", 9) == 0 and as_count("100", 9) == 100 and as_count("-3", 9) == -3;
    assert as_count("abc", 9) == 9 and as_count(None, 9) == 9 and as_count(True, 9) == 9;
    assert as_count(5, 9) == 5 and as_count(5.7, 9) == 5 and as_count(float("inf"), 9) == 9;
    assert as_flag("True", False) and not as_flag("False", True) and not as_flag(False, True);
    assert as_flag("no", True) and not as_flag(None, False);
}

test "a field that cannot be a name is left out" {
    sent: list[any] = [{"field": ["market_cap"], "min": 1}, {"field": None, "min": 1}, {"field": 3, "min": 1}];
    assert read_filters(sent, {"market_cap"}) == [];
}

test "a row missing a filtered figure does not match" {
    assert not RowFilter(field="market_cap", low=1.0).matches(row("C", None));
    assert RowFilter(field="market_cap", low=1.0, high=10.0).matches(row("A", 10.0));
    assert not RowFilter(field="sector", one_of=["Utilities"]).matches(row("A", 10.0));
}

test "a missing figure sorts last in either direction, and ties fall to the symbol" {
    (down, total) = run_query(ROWS, [], "", [], "market_cap", True, 0, 10);
    assert symbols_of(down) == ["B", "E", "D", "A", "C"] and total == 5;
    (up, _) = run_query(ROWS, [], "", [], "market_cap", False, 0, 10);
    assert symbols_of(up) == ["A", "D", "B", "E", "C"];
}

test "words sort without regard to case" {
    rows = [row("A", name="beta"), row("B", name="Alpha"), row("C", name="Gamma")];
    (found, _) = run_query(rows, [], "", [], "name", False, 0, 10);
    assert symbols_of(found) == ["B", "A", "C"];
}

test "search finds a symbol's start or a word in the name" {
    rows = [row("AAPL", name="Apple Inc."), row("PINE", name="Pinewood"), row("MAPL", name="Maple Foods")];
    assert symbols_of(run_query(rows, [], "aa", [], "symbol", False, 0, 10)[0]) == ["AAPL"];
    assert symbols_of(run_query(rows, [], "ple", [], "symbol", False, 0, 10)[0]) == ["AAPL", "MAPL"];
    assert symbols_of(run_query(rows, [], "  ", [], "symbol", False, 0, 10)[0]) == ["AAPL", "MAPL", "PINE"];
}

test "a watchlist limits the rows, and paging walks them whole" {
    assert symbols_of(run_query(ROWS, [], "", ["D", "A", "ZZZ"], "symbol", False, 0, 10)[0]) == ["A", "D"];
    (first, total) = run_query(ROWS, [], "", [], "symbol", False, 0, 2);
    (second, _) = run_query(ROWS, [], "", [], "symbol", False, 2, 2);
    (last, _) = run_query(ROWS, [], "", [], "symbol", False, 4, 2);
    assert symbols_of(first + second + last) == ["A", "B", "C", "D", "E"] and total == 5;
    assert len(run_query([row(str(i)) for i in range(500)], [], "", [], "symbol", False, -3, 100000)[0]) == MAX_LIMIT;
}

test "peers are the same industry nearest in size, then the sector, never the same company" {
    me = row("ME", 100.0, name="Me Inc");
    others = [
        me,
        row("MEB", 100.0, name="Me Inc"),
        row("FAR", 1000.0),
        row("NEAR", 110.0),
        row("SECT", 100.0, industry="Gas"),
        row("OTHER", 100.0, sector="Utilities", industry="Power"),
        row("NOCAP", None)
    ];
    assert symbols_of(peers_of(me, others)) == ["NEAR", "FAR", "SECT"];
    assert symbols_of(peers_of(me, others, limit=1)) == ["NEAR"];
}

test "a stock with no size yet is shown its industry's largest" {
    me = row("ME", None, name="Me Inc");
    others = [me, row("SMALL", 1.0), row("BIG", 1000.0), row("MID", 50.0), row("NOCAP", None)];
    assert symbols_of(peers_of(me, others)) == ["BIG", "MID", "SMALL"];
}

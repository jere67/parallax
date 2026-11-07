"""A screen written to the address and read back (dashboard/market/screen_url.jac)."""
import from dashboard.market.screen_url { Bound, Screen, columns_of, descending_of, pills_of, read_screen, request_filter, sort_of, write_screen }
import from dashboard.market.columns { COLUMN_SETS, DEFAULT_FILTERS, FIELD_BY_KEY, FIELDS, big_money, days_from, show, size_class, tone_of }

test "a default screen writes nothing" {
    assert write_screen(Screen()) == {};
    assert read_screen({}).tab == "Overview";
}

test "a screen survives the address" {
    screen = Screen(
        tab="Performance",
        sort="perf_1y",
        ascending=True,
        search="bank",
        watch_only=True,
        added=["beta"],
        columns=["price", "pe"],
        filters={"pe": Bound(low=5.0, high=20.0), "sector": Bound(one_of=["Energy", "Utilities"]), "price": Bound(high=50.0)}
    );
    again = read_screen(write_screen(screen));
    assert again.tab == "Performance" and again.sort == "perf_1y" and again.ascending;
    assert again.search == "bank" and again.watch_only;
    assert again.added == ["beta"] and again.columns == ["price", "pe"];
    assert again.filters["pe"].low == 5.0 and again.filters["pe"].high == 20.0;
    assert again.filters["price"].low is None and again.filters["price"].high == 50.0;
    assert again.filters["sector"].one_of == ["Energy", "Utilities"];
}

test "an old or mangled link still opens" {
    screen = read_screen({"tab": "Nope", "sort": "nope", "add": "nope,beta", "cols": "nope", "f": "nope:1:2;pe:x;pe::;sector~;price:1:"});
    assert screen.tab == "Overview" and screen.sort == "";
    assert screen.added == ["beta"] and screen.columns == [];
    assert list(screen.filters.keys()) == ["price"];
}

test "a filter that does not parse as a number is left out" {
    assert read_screen({"f": "pe:abc:def"}).filters == {};
}

test "a tab supplies its own columns and sort until a reader overrides them" {
    screen = read_screen({"tab": "Performance"});
    assert len(columns_of(screen)) > 0 and sort_of(screen) in FIELD_BY_KEY;
    assert descending_of(read_screen({"sort": "pe"}));
    assert not descending_of(read_screen({"sort": "pe", "asc": "1"}));
    assert columns_of(read_screen({"cols": "price,pe"})) == ["price", "pe"];
}

test "pills are the defaults, then added ones, then any field filtered through a link" {
    pills = pills_of(read_screen({"add": "beta", "f": "roa:1:"}));
    assert pills[0:len(DEFAULT_FILTERS)] == DEFAULT_FILTERS;
    assert "beta" in pills and "roa" in pills;
    assert len(pills) == len(set(pills));
}

test "a bound goes to the endpoint in the row's own units" {
    assert request_filter("sector", Bound(one_of=["Energy"])) == {"field": "sector", "one_of": ["Energy"]};
    scale = FIELD_BY_KEY["dividend_yield"].scale;
    assert request_filter("dividend_yield", Bound(low=2.0)) == {"field": "dividend_yield", "min": 2.0 * scale};
    assert request_filter("price", Bound(high=5.0)) == {"field": "price", "max": 5.0 * FIELD_BY_KEY["price"].scale};
}

test "every column and filter names a field, and no field repeats" {
    assert len(FIELD_BY_KEY) == len(FIELDS);
    for set_ in COLUMN_SETS {
        for key in set_.columns + [set_.sort] {
            assert key in FIELD_BY_KEY, f"{set_.name}: {key}";
        }
    }
    for key in DEFAULT_FILTERS {
        assert key in FIELD_BY_KEY, key;
    }
}

test "money, days, and size read the way a reader expects" {
    assert big_money(3.41e12) == "$3.41T";
    assert big_money(-2.5e9) == "-$2.50B";
    assert big_money(12.4e6) == "$12.4M";
    assert big_money(None) == "-";
    assert days_from(0.0) == "Today" and days_from(1.0) == "Tomorrow" and days_from(-1.0) == "Yesterday";
    assert days_from(5.0) == "In 5 days" and days_from(-3.0) == "3 days ago";
    assert size_class(3e12) == "Mega cap" and size_class(1e10) == "Large cap" and size_class(1e6) == "Micro cap";
    assert size_class(None) == "";
}

test "a value shows by its field, and a missing one as a dash" {
    assert show("price", None) == "-" and show("sector", "") == "-";
    assert show("market_cap", 2e9) == "$2.00B";
    assert show("sector", "Energy") == "Energy";
    assert tone_of("change_pct", -0.1) == "text-down" and tone_of("change_pct", 0.1) == "text-up";
    assert tone_of("analyst_rating", "Buy") == "text-up" and tone_of("analyst_rating", "Sell") == "text-down";
    assert tone_of("price", None) == "text-faint";
}

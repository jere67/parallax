"""The market endpoints on a demo server's invented market: no source, and no argument trusted."""
import os;
import from market.api { get_stock_about, get_stock_history, screen_stocks }
import from market.demo { DEMO_ENV }

test "the endpoints answer a demo server without any source" {
    before = os.environ.get(DEMO_ENV);
    os.environ[DEMO_ENV] = "1";
    try {
        view = screen_stocks(filters=[{"field": "sector", "one_of": ["Energy"]}], columns=["price", "sector"], limit=5);
        assert view.demo and view.ready and view.total > 0;
        assert all(r["sector"] == "Energy" for r in view.rows);
        assert "pe" not in view.rows[0] and "symbol" in view.rows[0];
        history = get_stock_history("AAPL");
        assert history.daily and history.intraday and history.seasons;
        assert get_stock_about("aapl").description;
        # What the server passes for arguments left out of a request, and what anyone might send.
        unsent: any = {"filters": "[]", "search": "", "symbols": "[]", "sort": "market_cap", "descending": "True", "columns": "[]", "offset": "0", "limit": "100"};
        assert screen_stocks(**unsent).total == len(screen_stocks().rows);
        odd: any = {"filters": 5, "search": None, "symbols": {"a": 1}, "sort": ["x"], "descending": "?", "columns": [1, None], "offset": "x", "limit": None};
        assert screen_stocks(**odd).rows;
        assert get_stock_history("NOPE!").daily == [];
        assert get_stock_about("NOPE!").description == "";
    } finally {
        if before is None {
            del os.environ[DEMO_ENV];
        } else {
            os.environ[DEMO_ENV] = before;
        }
    }
}

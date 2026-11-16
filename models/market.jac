"""What the market pages' endpoints return (market/api.jac). As in models/views.jac, the views carry
numbers rather than formatted text, returns and ratios are fractions, a figure nobody has is None,
and dates are "YYYY-MM-DD". A row is a plain dictionary because a page asks only for the columns it
shows; `dashboard/market/columns.jac` names what each field means.
"""

"""How much of the market each sweep has reached, for the note under the table."""
obj CoverageView {
    has stocks: int = 0,
        priced: int = 0,
        with_stats: int = 0,
        with_figures: int = 0,
        with_analysts: int = 0;
}

"""One page of the screener. `decisions` holds the action the reader's agent took on each of the
page's stocks it covered in its latest run that covered stocks (a weekend run covers coins alone),
the one on `decided_day`, so a row can link to that decision's trail."""
obj ScreenerView {
    has rows: list[dict[str, float | str | None]] = [],
        decisions: dict[str, str] = {},
        decided_day: str = "",
        total: int = 0,
        ready: bool = False,
        demo: bool = False,
        as_of: str = "",
        quote_day: str = "",
        sectors: list[str] = [],
        exchanges: list[str] = [],
        coverage: CoverageView = CoverageView();
}

"""One stock in a row of comparable stocks."""
obj PeerView {
    has symbol: str,
        name: str,
        price: float | None = None,
        change_pct: float | None = None,
        market_cap: float | None = None,
        pe: float | None = None;
}

"""One reported period for the financials charts: FY2025 or Q3 2026, with what it reports."""
obj PeriodView {
    has end: str,
        label: str,
        values: dict[str, float] = {};
}

obj FilingView {
    has form: str,
        filed: str,
        report_date: str,
        url: str;
}

"""One indicator's reading and its vote: 1 buy, -1 sell, 0 neutral, or None without the data."""
obj SignalView {
    has name: str,
        value: float | None = None,
        vote: int | None = None;
}

"""One month's analyst consensus as a -1 to 1 score."""
obj RatingPointView {
    has period: str,
        score: float,
        analysts: int;
}

"""How far one reported quarter beat or missed the consensus, in percent."""
obj SurpriseView {
    has period: str,
        surprise_pct: float | None = None;
}

"""Who a company is, from its SEC filings and, for the website and IPO date, Finnhub."""
obj ProfileView {
    has cik: str = "",
        headquarters: str = "",
        incorporated: str = "",
        fiscal_year_end: str = "",
        ein: str = "",
        sic: int = 0,
        sic_description: str = "",
        filer_category: str = "",
        website: str = "",
        ipo: str = "",
        edgar_url: str = "";
}

"""What the investment committee last did about a stock, when it has looked at it."""
obj CommitteeView {
    has held: bool = False,
        held_qty: float | None = None,
        run_day: str = "",
        action: str = "",
        trail: str = "";
}

"""One stock's page, without the parts fetched separately. `values` is its full row."""
obj StockView {
    has found: bool,
        symbol: str;
    has name: str = "",
        demo: bool = False,
        as_of: str = "",
        market_phase: str = "",
        values: dict[str, float | str | None] = {},
        profile: ProfileView = ProfileView(),
        peers: list[PeerView] = [],
        annual: list[PeriodView] = [],
        quarterly: list[PeriodView] = [],
        filings: list[FilingView] = [],
        signals: list[SignalView] = [],
        rating_trend: list[RatingPointView] = [],
        surprises: list[SurpriseView] = [],
        committee: CommitteeView = CommitteeView();
}

"""One bar for the price chart. `time` is a "YYYY-MM-DD" session, or Unix seconds for intraday."""
obj BarView {
    has time: str | int,
        open: float,
        high: float,
        low: float,
        close: float,
        volume: float;
}

"""A stock's returns by calendar month. `months` runs January to December; a month the record does
not cover is None."""
obj SeasonView {
    has year: int,
        months: list[float | None],
        total: float | None = None;
}

"""A stock's price history: daily bars back to 2016, five sessions of intraday bars, and returns by
month. `busy` means the page asked while the shared allowance was spent, so it should retry."""
obj HistoryView {
    has symbol: str;
    has daily: list[BarView] = [],
        intraday: list[BarView] = [],
        seasons: list[SeasonView] = [],
        busy: bool = False;
}

obj NewsItemView {
    has headline: str,
        source: str,
        url: str,
        at: str;
}

"""A stock's recent headlines and, from Wikipedia, a short description with a link to its article."""
obj StockAboutView {
    has symbol: str;
    has news: list[NewsItemView] = [],
        description: str = "",
        description_url: str = "",
        busy: bool = False;
}

"""One coin's page (market/api.jac `get_coin`), or `found=False` for a pair the screener does not
cover. `values` is its full screener row; `daily` its kept daily bars, a UTC day each."""
obj CoinView {
    has found: bool,
        symbol: str;
    has name: str = "",
        values: dict[str, float | str | None] = {},
        daily: list[BarView] = [],
        committee: CommitteeView = CommitteeView(),
        demo: bool = False,
        as_of: str = "",
        stats_day: str = "";
}

"""One side of a strike in an option chain: the contract and its latest quote, trade, day's volume,
open interest, implied volatility, and delta, and how many contracts the reader's agent holds."""
obj OptionSideView {
    has symbol: str;
    has bid: float | None = None,
        ask: float | None = None,
        last: float | None = None,
        volume: float | None = None,
        open_interest: float | None = None,
        iv: float | None = None,
        delta: float | None = None,
        held: float = 0.0;
}

obj OptionStrikeView {
    has strike: float;
    has call: OptionSideView | None = None,
        put: OptionSideView | None = None;
}

"""A stock's option chain for one expiry (market/api.jac `get_option_chain`). `expiries` are every
listed expiry within the chain's window, `price` the stock's price the strikes are around, and
`busy` asks the page to try again shortly."""
obj OptionChainView {
    has symbol: str;
    has found: bool = False,
        price: float | None = None,
        expiries: list[str] = [],
        expiry: str = "",
        strikes: list[OptionStrikeView] = [],
        demo: bool = False,
        busy: bool = False,
        message: str = "";
}

"""One contract the reader's agent holds, held, or ordered, for the screener's Options view."""
obj OptionHoldingView {
    has contract: str,
        label: str,
        underlying: str,
        kind: str,
        strike: float,
        expiry: str,
        status: str;
    has days_left: int | None = None,
        qty: float = 0.0,
        entry_price: float | None = None,
        last: float | None = None,
        value: float | None = None,
        pnl: float | None = None,
        pnl_pct: float | None = None,
        decision_day: str = "",
        at: str = "";
}

obj OptionBookView {
    has rows: list[OptionHoldingView] = [],
        demo: bool = False;
}

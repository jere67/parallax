"""What the dashboard's endpoints return (TDD §10): read-only views of the team graph, built by
dashboard/api.jac and sent to the pages as typed objects.

The views carry numbers, not formatted text, so the pages decide how to show them. Money is
in dollars, returns and weights are fractions (0.012 is 1.2%), dates are "YYYY-MM-DD" in New
York time, and timestamps are ISO 8601 in UTC, as in models/graph.jac. A figure the record
does not have is None, never zero.
"""

"""One portfolio's equity after one session's close."""
obj MarkPoint {
    has day: str,
        equity: float,
        drawdown: float;
}

"""One equity curve: the team portfolio or a baseline, with its summary statistics.
`total_return` is against the starting balance; `sharpe` is annualized from daily returns
with a zero risk-free rate and needs at least two of them."""
obj Series {
    has key: str,
        label: str,
        points: list[MarkPoint];
    has total_return: float | None = None,
        sharpe: float | None = None,
        max_drawdown: float | None = None,
        volatility: float | None = None;
}

obj PerformanceView {
    has started: bool;
    has start_day: str = "",
        starting_cash: float = 0.0,
        series: list[Series] = [];
}

"""A position, open or closed. `last_price` is the price at the last mark (or the fill, for a
position opened since); a closed position's P&L is realized at `exit_price`."""
obj PositionView {
    has ticker: str,
        sector: str,
        qty: int,
        avg_entry_price: float,
        opened_at: str;
    has last_price: float | None = None,
        priced_at: str = "",
        market_value: float | None = None,
        weight: float | None = None,
        pnl: float | None = None,
        pnl_pct: float | None = None,
        stop_price: float | None = None,
        stop_distance: float | None = None,
        time_stop: str = "",
        closed_at: str = "",
        exit_price: float | None = None,
        entry_qty: int = 0,
        thesis: str = "",
        decision_day: str = "";
}

obj FillView {
    has qty: int,
        price: float,
        filled_at: str;
}

"""An order the executor sent (or that Alpaca refused), with its fills. `run_day` links it to
the decision behind it; a stop has none."""
obj OrderView {
    has client_order_id: str,
        ticker: str,
        purpose: str,
        side: str,
        qty: int,
        order_type: str,
        time_in_force: str,
        status: str,
        submitted_at: str;
    has limit_price: float | None = None,
        stop_price: float | None = None,
        filled_qty: int = 0,
        filled_avg_price: float | None = None,
        updated_at: str = "",
        reject_reason: str = "",
        run_day: str = "",
        fills: list[FillView] = [];
}

"""The team portfolio at its last mark. Before the forward test starts there is no mark, so
`started` is False and the figures are empty."""
obj PortfolioView {
    has name: str,
        mode: str,
        started: bool;
    has demo: bool = False,
        opened_at: str = "",
        starting_cash: float = 0.0,
        as_of: str = "",
        last_day: str = "",
        equity: float | None = None,
        cash: float | None = None,
        positions_value: float | None = None,
        day_pnl: float | None = None,
        day_return: float | None = None,
        total_pnl: float | None = None,
        total_return: float | None = None,
        peak_equity: float | None = None,
        drawdown: float | None = None,
        gross_exposure: float | None = None,
        sessions: int = 0,
        bypasses: int = 0,
        drift: int = 0,
        positions: list[PositionView] = [],
        closed: list[PositionView] = [],
        orders: list[OrderView] = [];
}

"""The macro brief and the market figures the regime filter reads."""
obj MacroView {
    has regime: str,
        confidence: float,
        summary: str;
    has risks: list[str] = [],
        spy_close: float | None = None,
        spy_sma_200: float | None = None,
        spy_vol_20: float | None = None;
}

"""One covered ticker's line in a run: why it was covered, what the panel and the Arbiter
decided, what the gate allowed, and what was ordered."""
obj CoverageRow {
    has ticker: str,
        sector: str,
        reason: str;
    has reason_note: str = "",
        screen_score: float | None = None,
        flag_reason: str = "",
        last_close: float | None = None,
        action: str = "",
        conviction: float | None = None,
        draft_action: str = "",
        downgraded: bool = False,
        forced_hold: bool = False,
        score: float | None = None,
        agreement: float | None = None,
        ci_low: float | None = None,
        ci_high: float | None = None,
        gate_outcome: str = "",
        requested_qty: int = 0,
        approved_qty: int = 0,
        rejected_by: str = "",
        order_status: str = "",
        order_side: str = "",
        order_qty: int = 0,
        filled_qty: int = 0,
        filled_avg_price: float | None = None;
}

"""A run in the list of runs."""
obj RunSummary {
    has run_date: str,
        status: str;
    has covered: int = 0,
        trades: int = 0,
        actions: dict[str, int] = {};
}

obj RunView {
    has run_date: str,
        status: str,
        mode: str;
    has demo: bool = False,
        reduced_mode: bool = False,
        started_at: str = "",
        finished_at: str = "",
        executed_at: str = "",
        reconciled_at: str = "",
        execution_note: str = "",
        summary: str = "",
        model_requests: int = 0,
        prompt_tokens: int = 0,
        completion_tokens: int = 0,
        macro: MacroView | None = None,
        rows: list[CoverageRow] = [],
        action_log: list[str] = [],
        previous_day: str = "",
        next_day: str = "";
}

obj EvidenceView {
    has claim: str,
        source_url: str,
        published: str;
    has host: str = "";
}

"""One research report on the ticker (or the run's macro brief)."""
obj ResearchView {
    has domain: str,
        view: str,
        confidence: float,
        summary: str;
    has evidence: list[EvidenceView] = [],
        risks: list[str] = [],
        data_gaps: list[str] = [],
        model: str = "",
        as_of: str = "",
        followup_question: str = "";
}

"""One specialist sample. `signed` is stance / 2 x confidence in [-1, 1], the number the
consensus averages; `excess_return` and `hit` arrive once the vote's window closes. `cited`
holds positions in the specialist's evidence packet, and `sources` the evidence they name."""
obj SampleView {
    has sample: int,
        stance: str,
        confidence: float,
        signed: float,
        horizon_days: int,
        rationale: str;
    has cited: list[int] = [],
        sources: list[EvidenceView] = [],
        excess_return: float | None = None,
        hit: bool | None = None;
}

obj SpecialistView {
    has specialist: str,
        score: float;
    has weight: float | None = None,
        samples: list[SampleView] = [];
}

obj ConsensusView {
    has score: float,
        agreement: float,
        ci_low: float,
        ci_high: float,
        draft_action: str;
    has samples_used: int = 0,
        samples_dropped: int = 0;
}

obj DecisionView {
    has action: str,
        conviction: float;
    has thesis: str = "",
        risks: list[str] = [],
        exit_condition: str = "",
        time_stop: str = "",
        arbiter_verdict: str = "",
        downgrade_reason: str = "",
        forced_hold_reason: str = "",
        model: str = "";
}

obj RuleView {
    has rule: str,
        passed: bool;
    has detail: str = "",
        qty_before: int = 0,
        qty_after: int = 0;
}

obj GateView {
    has outcome: str,
        side: str,
        purpose: str,
        requested_qty: int,
        approved_qty: int,
        checked_at: str;
    has price: float | None = None,
        stop_distance: float | None = None,
        gate_version: str = "",
        rules: list[RuleView] = [];
}

"""One ticker's full trail in one run (TDD §10, Decision detail): the evidence, every vote,
the consensus, the Arbiter's decision, the risk gate, and the orders and fills, with the
position the decision opened. `tickers` lists the run's covered tickers in order, for
moving between decisions."""
obj TrailView {
    has run_date: str,
        ticker: str,
        sector: str,
        reason: str,
        run_status: str,
        mode: str;
    has demo: bool = False,
        reason_note: str = "",
        screen_score: float | None = None,
        flag_reason: str = "",
        fetch_errors: list[str] = [],
        last_close: float | None = None,
        atr_14: float | None = None,
        realized_vol_20: float | None = None,
        volume_20: float | None = None,
        sessions_to_earnings: int | None = None,
        research: list[ResearchView] = [],
        macro: MacroView | None = None,
        specialists: list[SpecialistView] = [],
        consensus: ConsensusView | None = None,
        decision: DecisionView | None = None,
        gate: GateView | None = None,
        orders: list[OrderView] = [],
        position: PositionView | None = None,
        tickers: list[str] = [],
        disclaimer: str = "";
}

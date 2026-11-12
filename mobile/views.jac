"""The shapes of the server's views that the phone reads, a subset of models/views.jac in the
Parallax server. Replies arrive as JSON and are read through these types, so the screens'
attribute reads are checked; a field the server leaves out reads as None."""

obj MarkPoint {
    has day: str = "",
        equity: float = 0.0,
        drawdown: float = 0.0;
}

obj Series {
    has key: str = "",
        label: str = "",
        points: list[MarkPoint] = [],
        total_return: float | None = None;
}

obj PerformanceView {
    has started: bool = False,
        start_day: str = "",
        starting_cash: float = 0.0,
        series: list[Series] = [];
}

obj PositionView {
    has ticker: str = "",
        sector: str = "",
        qty: int = 0,
        avg_entry_price: float = 0.0,
        opened_at: str = "",
        last_price: float | None = None,
        market_value: float | None = None,
        weight: float | None = None,
        pnl: float | None = None,
        pnl_pct: float | None = None,
        stop_price: float | None = None,
        thesis: str = "",
        decision_day: str = "";
}

obj PortfolioView {
    has name: str = "",
        mode: str = "",
        started: bool = False,
        demo: bool = False,
        as_of: str = "",
        last_day: str = "",
        starting_cash: float = 0.0,
        equity: float | None = None,
        cash: float | None = None,
        positions_value: float | None = None,
        day_pnl: float | None = None,
        day_return: float | None = None,
        total_pnl: float | None = None,
        total_return: float | None = None,
        drawdown: float | None = None,
        gross_exposure: float | None = None,
        sessions: int = 0,
        positions: list[PositionView] = [],
        live_at: str = "";
}

obj MacroView {
    has regime: str = "",
        confidence: float = 0.0,
        summary: str = "",
        risks: list[str] = [];
}

obj CoverageRow {
    has ticker: str = "",
        sector: str = "",
        reason: str = "",
        reason_note: str = "",
        action: str = "",
        conviction: float | None = None,
        forced_hold: bool = False,
        downgraded: bool = False,
        score: float | None = None,
        gate_outcome: str = "",
        approved_qty: int = 0,
        order_status: str = "",
        order_side: str = "",
        order_qty: int = 0,
        filled_qty: int = 0,
        filled_avg_price: float | None = None;
}

obj RunView {
    has run_date: str = "",
        status: str = "",
        mode: str = "",
        demo: bool = False,
        started_at: str = "",
        finished_at: str = "",
        executed_at: str = "",
        execution_summary: str = "",
        execution_detail: str = "",
        summary: str = "",
        model_requests: int = 0,
        macro: MacroView | None = None,
        rows: list[CoverageRow] = [],
        previous_day: str = "",
        next_day: str = "";
}

obj EvidenceView {
    has claim: str = "",
        source_url: str = "",
        published: str = "",
        host: str = "";
}

obj ResearchView {
    has domain: str = "",
        view: str = "",
        confidence: float = 0.0,
        summary: str = "",
        evidence: list[EvidenceView] = [],
        risks: list[str] = [],
        data_gaps: list[str] = [];
}

obj SampleView {
    has sample: int = 0,
        stance: str = "",
        confidence: float = 0.0,
        signed: float = 0.0,
        rationale: str = "",
        abstained: bool = False;
}

obj SpecialistView {
    has specialist: str = "",
        score: float = 0.0,
        weight: float | None = None,
        samples: list[SampleView] = [],
        status: str = "voted",
        errors: list[str] = [];
}

obj ConsensusView {
    has score: float = 0.0,
        agreement: float = 0.0,
        ci_low: float = 0.0,
        ci_high: float = 0.0,
        draft_action: str = "";
}

obj DecisionView {
    has action: str = "",
        conviction: float = 0.0,
        thesis: str = "",
        risks: list[str] = [],
        exit_condition: str = "",
        arbiter_verdict: str = "",
        downgrade_reason: str = "",
        forced_hold_reason: str = "";
}

obj RuleView {
    has rule: str = "",
        passed: bool = False,
        detail: str = "";
}

obj GateView {
    has outcome: str = "",
        side: str = "",
        requested_qty: int = 0,
        approved_qty: int = 0,
        rules: list[RuleView] = [];
}

obj OrderView {
    has client_order_id: str = "",
        ticker: str = "",
        purpose: str = "",
        side: str = "",
        qty: int = 0,
        status: str = "",
        submitted_at: str = "",
        filled_qty: int = 0,
        filled_avg_price: float | None = None,
        reject_reason: str = "";
}

obj TrailView {
    has run_date: str = "",
        ticker: str = "",
        sector: str = "",
        reason: str = "",
        run_status: str = "",
        demo: bool = False,
        decision_id: str = "",
        last_close: float | None = None,
        research: list[ResearchView] = [],
        specialists: list[SpecialistView] = [],
        consensus: ConsensusView | None = None,
        decision: DecisionView | None = None,
        gate: GateView | None = None,
        orders: list[OrderView] = [],
        tickers: list[str] = [],
        disclaimer: str = "";
}

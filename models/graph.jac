"""The team graph on root.shared (TDD §11).

    root.shared
      └─ Portfolio
           ├─ Holds ──> Position ──OpenedBy──> Decision
           │              └─ StoppedBy ──> Order (its protective stops)
           ├─ Sent ──> Order (every order, for reconciliation)
           ├─ Marked ──> DailyMark(day) (the 4:30 p.m. mark and reconciliation)
           ├─ Counted ──> RequestCount(day)
           └─ Ran ──> Run(run_date)
                ├─ HasMacro ──> MacroRecord
                └─ Covers ──> Coverage(ticker)
                     ├─ Researched ──> ResearchRecord (one per domain)
                     ├─ Voted ──> VoteRecord (one per specialist sample)
                     ├─ Concluded ──> ConsensusResult
                     ├─ Decided ──> Decision ──CheckedBy──> RiskCheck ──Placed──> Order ──FilledBy──> Fill
                     └─ Published ──> InsightCard

This module's path is frozen: moving a node type to another module quarantines its stored
rows until a schema rule maps the old path (TDD §11, schema changes). Add fields with
defaults freely; rename fields only with schema_alias.

Timestamps are ISO 8601 strings in UTC, and trading dates are "YYYY-MM-DD" in New York time
(TDD §3, rule 11).
"""
import from models.agents { Domain, MacroReport, ResearchReport, Specialist, Vote }
import from models.research { RegimeInputs }

enum PortfolioMode: str {
    AUTO = "auto",
    INSIGHT = "insight"
}

enum RunStatus: str {
    RUNNING = "running",
    NORMAL = "normal",
    FALLBACK = "fallback",
    SKIPPED = "skipped",
    FAILED = "failed"
}

enum CoverageReason: str {
    SCREEN = "screen",
    HELD = "held",
    WILDCARD = "wildcard",
    USER_REQUEST = "user_request"
}

enum TradeAction: str {
    BUY = "BUY",
    ADD = "ADD",
    HOLD = "HOLD",
    TRIM = "TRIM",
    SELL = "SELL",
    NO_ACTION = "NO_ACTION"
}

enum RiskOutcome: str {
    APPROVED = "approved",
    RESIZED = "resized",
    REJECTED = "rejected"
}

enum OrderSide: str {
    BUY = "buy",
    SELL = "sell"
}

enum OrderPurpose: str {
    ENTRY = "entry",
    ADD = "add",
    EXIT = "exit",
    TRIM = "trim",
    STOP = "stop"
}

node Portfolio {
    has name: str,
        mode: PortfolioMode,
        starting_cash: float,
        opened_at: str;
    has peak_equity: float = 0.0;
}

"""A position the team portfolio holds or held. `stop_price` is where its protective stop
sits; `stops_placed` numbers its stop orders, so each gets a fresh client order ID. A closed
position keeps its node, with `closed_at` set, so the dashboard can show its history."""
node Position {
    has ticker: str,
        sector: str,
        qty: int,
        avg_entry_price: float,
        opened_at: str;
    has stop_price: float = 0.0,
        stop_order_id: str = "",
        stops_placed: int = 0,
        closed_at: str = "",
        exit_price: float = 0.0;

    def open -> bool {
        return not self.closed_at;
    }
}

node Run {
    has run_date: str,
        started_at: str;
    has status: RunStatus = RunStatus.RUNNING,
        reduced_mode: bool = False,
        finished_at: str = "",
        executed_at: str = "",
        execution_note: str = "",
        day_orders_closed_at: str = "",
        reconciled_at: str = "",
        action_log: list[str] = [],
        summary: str = "",
        model_versions: dict[str, str] = {},
        model_requests: int = 0,
        prompt_tokens: int = 0,
        completion_tokens: int = 0;
}

"""Free-model requests the app made on one UTC day (TDD §12, request controls), kept in the
graph so the count survives a restart. `day` is "YYYY-MM-DD" in UTC."""
node RequestCount {
    has day: str,
        used: int;
}

node MacroRecord {
    has as_of: str,
        model: str,
        body: MacroReport;
    has inputs: RegimeInputs | None = None;
}

"""One ticker in one run. The market figures at the end are what the Action layer sizes and
gates with (TDD §8), stored with the run because execution runs as a later job: the last
close, ATR(14), 20-day realized volatility, 20-day average volume in shares, and trading
sessions to the next earnings release (None when none is known within the calendar)."""
node Coverage {
    has ticker: str,
        sector: str,
        reason: CoverageReason;
    has screen_score: float = 0.0,
        reason_note: str = "",
        fetch_errors: list[str] = [],
        flag_reason: str = "",
        last_close: float = 0.0,
        atr_14: float | None = None,
        realized_vol_20: float | None = None,
        volume_20: float | None = None,
        sessions_to_earnings: int | None = None;
}

node ResearchRecord {
    has ticker: str,
        domain: Domain,
        as_of: str,
        model: str,
        body: ResearchReport;
    has followup_question: str = "";
}

node VoteRecord {
    has ticker: str,
        specialist: Specialist,
        sample: int,
        model: str,
        body: Vote;
    has excess_return: float | None = None,
        scored_at: str = "";
}

node ConsensusResult {
    has ticker: str,
        score: float,
        agreement: float,
        ci_low: float,
        ci_high: float,
        draft_action: TradeAction;
    has specialist_scores: dict[str, float] = {},
        weights: dict[str, float] = {},
        samples_used: int = 0,
        samples_dropped: int = 0;
}

node Decision {
    has ticker: str,
        action: TradeAction,
        conviction: float;
    has thesis: str = "",
        risks: list[str] = [],
        exit_condition: str = "",
        time_stop: str = "",
        downgrade_reason: str = "",
        forced_hold_reason: str = "",
        arbiter_verdict: str = "",
        model: str = "";
}

obj RuleResult {
    has rule: str,
        passed: bool;
    has detail: str = "",
        qty_before: int = 0,
        qty_after: int = 0;
}

"""The risk gate's ruling on one sized order (TDD §8, risk gate). `price` is the latest trade
it was judged at, and `stop_distance` how far below the fill a buy's protective stop goes."""
node RiskCheck {
    has outcome: RiskOutcome,
        approved_qty: int,
        checked_at: str;
    has rules: list[RuleResult] = [],
        ticker: str = "",
        side: OrderSide | None = None,
        purpose: OrderPurpose | None = None,
        requested_qty: int = 0,
        price: float = 0.0,
        stop_distance: float = 0.0,
        gate_version: str = "";
}

"""One order sent to Alpaca, or refused by it (`status` "rejected" with the reason).
`filled_qty` and `filled_avg_price` are the cumulative fill Alpaca last reported; each
increase adds a Fill."""
node Order {
    has client_order_id: str,
        purpose: OrderPurpose,
        side: OrderSide,
        qty: int,
        order_type: str,
        time_in_force: str,
        submitted_at: str;
    has alpaca_order_id: str = "",
        limit_price: float = 0.0,
        stop_price: float = 0.0,
        status: str = "new",
        reject_reason: str = "",
        ticker: str = "",
        filled_qty: int = 0,
        filled_avg_price: float = 0.0,
        updated_at: str = "";
}

"""The portfolio after one trading day's close (TDD §8, reconciliation): equity, cash, and
positions as Alpaca reports them, the peak equity the drawdown breaker measures from, and
anything reconciliation found wrong. `drift` lists positions whose shares differ from the
record; `bypasses` lists orders not traced to a risk-gate approval or a position's stop,
which must stay empty (TDD §13, risk-gate bypasses)."""
node DailyMark {
    has day: str,
        equity: float,
        cash: float,
        positions_value: float,
        peak_equity: float,
        marked_at: str;
    has drawdown: float = 0.0,
        open_positions: int = 0,
        drift: list[str] = [],
        bypasses: list[str] = [];
}

node Fill {
    has qty: int,
        price: float,
        filled_at: str;
}

"""One specialist's samples on a card: each sample's stance and confidence, and the mean
signed score (stance / 2 x confidence) the consensus used."""
obj SpecialistTally {
    has specialist: str,
        score: float;
    has stances: list[str] = [],
        confidences: list[float] = [];
}

"""A source a card links to: the claim it supports and where it was published."""
obj SourceLink {
    has label: str,
        url: str;
    has published: str = "",
        domain: str = "";
}

"""A decision as a reader sees it (TDD §8, insight mode), rendered from the stored Decision,
votes, consensus, and research with no model request. `note` says why a decision is a
forced HOLD or a downgrade. Every card carries the disclaimer (TDD §9)."""
node InsightCard {
    has ticker: str,
        action: TradeAction,
        conviction: float,
        published_at: str;
    has run_date: str = "",
        mode: str = "",
        thesis: str = "",
        risks: list[str] = [],
        exit_condition: str = "",
        time_stop: str = "",
        score: float | None = None,
        agreement: float | None = None,
        ci_low: float | None = None,
        ci_high: float | None = None,
        specialists: list[SpecialistTally] = [],
        sources: list[SourceLink] = [],
        note: str = "",
        disclaimer: str = "";
}

edge Holds: Portfolio --> Position {}
edge Sent: Portfolio --> Order {}
edge Marked: Portfolio --> DailyMark {}
edge OpenedBy: Position --> Decision {}
edge StoppedBy: Position --> Order {}
edge Ran: Portfolio --> Run {}
edge Counted: Portfolio --> RequestCount {}
edge HasMacro: Run --> MacroRecord {}
edge Covers: Run --> Coverage {}
edge Researched: Coverage --> ResearchRecord {}
edge Voted: Coverage --> VoteRecord {}
edge Concluded: Coverage --> ConsensusResult {}
edge Decided: Coverage --> Decision {}
edge CheckedBy: Decision --> RiskCheck {}
edge Placed: RiskCheck --> Order {}
edge FilledBy: Order --> Fill {}
edge Published: Coverage --> InsightCard {}

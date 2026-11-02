"""The Today page (TDD §10): one morning run, newest by default. It shows the run's status and
timing, the macro brief, every covered ticker with the panel's consensus, the Arbiter's
action, the risk gate, and the order, and the list of past runs to move between."""
import from "@jac/runtime" { Link, useNavigate, useParams }
import from "lucide-react" { ChevronLeft, ChevronRight }
import from dashboard.api { get_run, list_runs }
import from dashboard.ui.IntervalBar { IntervalBar }
import from dashboard.ui.format {
    MISSING,
    compact,
    count,
    day_long,
    day_short,
    money,
    num,
    pct,
    qty,
    signed,
    time_et,
    time_range_et,
    title
}
import from dashboard.ui.parts {
    FROZEN_CELL,
    FROZEN_HEAD,
    PILL_BASE,
    ROW,
    SEGMENTS,
    TONE_DOWN,
    TONE_QUIET,
    TONE_UP,
    TD,
    TD_NUM,
    TH,
    TH_NUM,
    ActionBadge,
    Empty,
    ErrorBox,
    Field,
    Loading,
    Overline,
    Panel,
    Segment,
    StatusBadge
}
# Aliased: the endpoint bridge declares the wire classes under their own names.
import from models.views {
    CoverageRow as CoverageData,
    MacroView as MacroData,
    RunSummary as RunSummaryData,
    RunView as RunData
}

glob REASONS: dict[str, str] = {"screen": "Screen", "held": "Held", "wildcard": "Wildcard", "user_request": "Request"};
glob REGIMES: dict[str, str] = {"RISK_ON": "Risk on", "NEUTRAL": "Neutral", "RISK_OFF": "Risk off"};
glob REGIME_TONES: dict[str, str] = {"RISK_ON": TONE_UP, "NEUTRAL": TONE_QUIET, "RISK_OFF": TONE_DOWN};
glob BUYS: list[str] = ["BUY", "ADD"];
glob SELLS: list[str] = ["SELL", "TRIM"];
glob LOG_PREVIEW: int = 8;
# The shortlist's filters: a name, its label, and the actions it keeps ("" is no decision).
glob GROUPS: list[tuple[str, str, list[str]]] = [
    ("buys", "Buys", BUYS),
    ("sells", "Sells", SELLS),
    ("holds", "Holds", ["HOLD", "NO_ACTION", ""])
];

def count_of(actions: dict[str, int], names: list[str]) -> int {
    total = 0;
    for name in names {
        total += actions.get(name, 0);
    }
    return total;
}

def DayLink(day: str, label: str, forward: bool) -> JsxElement {
    base = "grid size-8 place-items-center ";
    icon = <ChevronRight size={16}/> if forward else <ChevronLeft size={16}/>;
    if not day {
        return <span className={base + "text-faint opacity-40"} aria-hidden="true">{icon}</span>;
    }
    <Link to={"/runs/" + day} className={base + "press text-muted hover:bg-hover hover:text-text"} aria-label={label} title={day_long(day)}>
        {icon}
    </Link>
}

"""The run's title: its day in the display face, its status, and the summary as the page's
description, with the previous and next runs at the right."""
def Header(run: RunData) -> JsxElement {
    <header className="flex flex-col gap-2">
        <div className="flex items-center justify-between gap-4">
            <Overline>{"Morning run · " + title(run.mode) + " mode"}</Overline>
            <nav className="flex shrink-0 overflow-hidden rounded-md border border-line bg-panel" aria-label="Runs">
                <DayLink day={run.previous_day} label="Previous run" forward={False}/>
                <span className="w-px bg-line" aria-hidden="true"></span>
                <DayLink day={run.next_day} label="Next run" forward={True}/>
            </nav>
        </div>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5">
            <h1 className="display text-[36px] leading-10 text-text">{day_long(run.run_date)}</h1>
            <StatusBadge status={run.status}/>
            {if run.reduced_mode {
                <StatusBadge status="fallback" label="Reduced mode"/>
            }}
        </div>
        <p className="max-w-[600px] text-[13px] leading-5 text-muted">{run.summary or "No summary was recorded."}</p>
    </header>
}

"""One fact in the run's strip: a label, a value, and a quieter line under it."""
def Fact(label: str, value: str, sub: str = "") -> JsxElement {
    <div className="min-w-0 bg-panel px-4 py-3">
        <Overline className="truncate">{label}</Overline>
        <div className="num mt-1 text-[15px] font-medium leading-5 text-pretty">{value}</div>
        <div className="num mt-0.5 truncate text-[11px] text-faint">{sub or "\u00a0"}</div>
    </div>
}

def Facts(run: RunData) -> JsxElement {
    screened = len([r for r in run.rows if r.reason == "screen"]);
    tokens = run.prompt_tokens + run.completion_tokens;
    <section className="grid grid-cols-2 gap-px overflow-hidden rounded-md border border-line bg-line sm:grid-cols-3 lg:grid-cols-6" aria-label="Run">
        <Fact label="Covered" value={count(len(run.rows), "ticker")} sub={str(screened) + " from the screen"}/>
        <Fact label="Risk gate" value={run.execution_note or MISSING}/>
        <Fact label="Analysis" value={time_range_et(run.started_at, run.finished_at)}/>
        <Fact label="Executed" value={time_et(run.executed_at)}/>
        <Fact label="Reconciled" value={time_et(run.reconciled_at)}/>
        <Fact label="Model" value={count(run.model_requests, "call")} sub={compact(float(tokens)) + " tokens"}/>
    </section>
}

def Macro(macro: MacroData | None) -> JsxElement {
    if macro is None {
        return <Panel title="Market"><p className="text-[13px] text-muted">No macro brief was recorded for this run.</p></Panel>;
    }
    above: bool | None = None;
    if macro.spy_close is not None and macro.spy_sma_200 is not None {
        above = macro.spy_close >= macro.spy_sma_200;
    }
    regime = <span className={PILL_BASE + " " + REGIME_TONES.get(macro.regime, TONE_QUIET)}>
        {REGIMES.get(macro.regime, macro.regime) + " · " + pct(macro.confidence, 0)}
    </span>;
    <Panel title="Market" aside={regime} pad={False}>
        <div className="grid grid-cols-3 gap-px border-b border-line bg-line">
            <Fact label="SPY close" value={money(macro.spy_close)}/>
            <Fact label="200-day avg" value={money(macro.spy_sma_200)} sub={("SPY above" if above else "SPY below") if above is not None else ""}/>
            <Fact label="20-day vol" value={pct(macro.spy_vol_20, 1)} sub="annualized"/>
        </div>
        <div className="p-4">
            <p className="text-[13px] leading-relaxed text-text">{macro.summary}</p>
            {if len(macro.risks) > 0 {
                <ul className="mt-3 flex flex-col gap-1.5 text-[12px] text-muted">
                    {for risk in macro.risks {
                        <li key={risk} className="flex gap-2">
                            <span className="mt-[7px] size-1 shrink-0 rounded-full bg-warn" aria-hidden="true"></span>
                            <span>{risk}</span>
                        </li>
                    }}
                </ul>
            }}
        </div>
    </Panel>
}

def CoveredCell(row: CoverageData) -> JsxElement {
    note = row.reason_note;
    if row.reason == "screen" and row.screen_score is not None {
        note = "score " + num(row.screen_score);
    }
    <div title={row.flag_reason}>
        <div>{REASONS.get(row.reason, title(row.reason))}</div>
        <div className="max-w-[160px] truncate text-[11px] text-faint">{note}</div>
    </div>
}

def DecisionCell(row: CoverageData) -> JsxElement {
    if not row.action {
        return <span className="text-faint">-</span>;
    }
    <div className="flex flex-col items-start gap-0.5">
        <ActionBadge action={row.action}/>
        {if row.downgraded {
            <span className="text-[11px] text-faint">{"Arbiter cut from " + row.draft_action}</span>
        } elif row.forced_hold {
            <span className="text-[11px] text-faint">Forced hold</span>
        }}
    </div>
}

def GateCell(row: CoverageData) -> JsxElement {
    if not row.gate_outcome {
        if row.action in BUYS or row.action in SELLS {
            return <div title="Sizing left no shares to trade, so nothing went to the risk gate">
                <div className="text-[12px] text-muted">Not sent</div>
                <div className="text-[11px] text-faint">sized to 0 shares</div>
            </div>;
        }
        return <span className="text-faint">-</span>;
    }
    <div className="flex flex-col items-start gap-0.5" title={row.rejected_by}>
        <StatusBadge status={row.gate_outcome}/>
        <span className="num text-[11px] text-faint">
            {(qty(row.approved_qty) + " of " + qty(row.requested_qty)) if row.gate_outcome != "rejected" else row.rejected_by}
        </span>
    </div>
}

def OrderCell(row: CoverageData) -> JsxElement {
    if not row.order_status {
        return <span className="text-faint">-</span>;
    }
    side = row.order_side.upper();
    <div className="flex flex-col items-start gap-0.5">
        <span className="num text-[12px]">
            <span className={"font-semibold " + ("text-up" if row.order_side == "buy" else "text-down")}>{side}</span>
            {" " + qty(row.filled_qty) + " of " + qty(row.order_qty)}
        </span>
        <span className="num text-[11px] text-faint">
            {("@ " + money(row.filled_avg_price)) if row.filled_avg_price is not None else row.order_status.replace("_", " ")}
        </span>
    </div>
}

def in_group(row: CoverageData, group: str) -> bool {
    for (name, _, actions) in GROUPS {
        if name == group {
            return row.action in actions;
        }
    }
    return True;
}

def CoverageTable(run: RunData) -> JsxElement {
    has group: str = "all";

    nav = useNavigate();
    rows = [r for r in run.rows if in_group(r, group)];
    filters = <div className={SEGMENTS}>
        <Segment label="All" count={len(run.rows)} active={group == "all"} pick={lambda { group = "all"; }}/>
        {for (name, label, _) in GROUPS {
            <Segment
                key={name}
                label={label}
                count={len([r for r in run.rows if in_group(r, name)])}
                active={group == name}
                pick={lambda { group = name; }}
            />
        }}
    </div>;
    <Panel title="Shortlist" aside={filters} pad={False}>
        {if len(run.rows) == 0 {
            <p className="px-4 py-6 text-[13px] text-muted">This run covered no tickers.</p>
        } elif len(rows) == 0 {
            <p className="px-4 py-6 text-[13px] text-muted">No ticker in this run came to that decision.</p>
        } else {
            <div className="scroll-x">
                <table className="w-full min-w-[1040px]">
                    <thead>
                        <tr>
                            <th className={TH + FROZEN_HEAD}>Ticker</th>
                            <th className={TH}>Decision</th>
                            <th className={TH_NUM}>Conviction</th>
                            <th className={TH}>Consensus</th>
                            <th className={TH_NUM}>Agreement</th>
                            <th className={TH}>Risk gate</th>
                            <th className={TH}>Order</th>
                            <th className={TH}>Covered</th>
                            <th className={TH_NUM}>Close</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for row in rows {
                            <tr
                                key={row.ticker}
                                className={ROW + " group cursor-pointer"}
                                onClick={lambda { nav("/runs/" + run.run_date + "/" + row.ticker); }}
                            >
                                <td className={TD + FROZEN_CELL}>
                                    <Link to={"/runs/" + run.run_date + "/" + row.ticker} className="font-semibold hover:text-accent">{row.ticker}</Link>
                                    <div className="max-w-[160px] truncate text-[11px] text-faint">{row.sector}</div>
                                </td>
                                <td className={TD}><DecisionCell row={row}/></td>
                                <td className={TD_NUM}>{num(row.conviction)}</td>
                                <td className={TD}>
                                    <div className="flex items-center gap-2.5">
                                        <IntervalBar score={row.score} low={row.ci_low} high={row.ci_high}/>
                                        <span className="num w-11 text-right text-[12px]">{signed(row.score)}</span>
                                    </div>
                                </td>
                                <td className={TD_NUM}>{pct(row.agreement, 0)}</td>
                                <td className={TD}><GateCell row={row}/></td>
                                <td className={TD}><OrderCell row={row}/></td>
                                <td className={TD}><CoveredCell row={row}/></td>
                                <td className={TD_NUM}>{money(row.last_close)}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
        }}
    </Panel>
}

def ActionLog(lines: list[str]) -> JsxElement {
    has expanded: bool = False;

    shown = lines if expanded else lines[:LOG_PREVIEW];
    more = len(lines) - LOG_PREVIEW;
    toggle = <button
        type="button"
        onClick={lambda { expanded = not expanded; }}
        className="text-[12px] font-medium text-accent hover:underline"
    >
        {"Show fewer" if expanded else "Show all " + str(len(lines))}
    </button>;
    <Panel title="Action log" aside={toggle if more > 0 else None} pad={False}>
        {if len(lines) == 0 {
            <p className="px-4 py-6 text-[13px] text-muted">Nothing was logged.</p>
        } else {
            <ol className="scroll-x font-mono text-[12px] leading-6 [&>li]:whitespace-nowrap">
                {for (i, line) in enumerate(shown) {
                    <li key={str(i)} className="border-b border-line/60 px-4 py-1 text-muted last:border-b-0">{line}</li>
                }}
            </ol>
        }}
    </Panel>
}

def RunList(runs: list[RunSummaryData], current: str) -> JsxElement {
    <Panel title="Runs" aside={<span className="num text-[12px] text-faint">{str(len(runs))}</span>} pad={False}>
        <ol className="max-h-[352px] overflow-y-auto overscroll-contain">
            {for r in runs {
                buys = count_of(r.actions, BUYS);
                sells = count_of(r.actions, SELLS);
                active = r.run_date == current;
                <li key={r.run_date}>
                    <Link
                        to={"/runs/" + r.run_date}
                        className={"relative flex items-center justify-between gap-3 border-b border-line/60 px-4 py-2 text-[13px] transition-colors duration-150 " + ("bg-accent-soft before:absolute before:inset-y-0 before:left-0 before:w-0.5 before:bg-accent" if active else "hover:bg-hover")}
                        aria-current={"page" if active else None}
                    >
                        <span className="flex items-center gap-2">
                            <span
                                className={"size-1.5 rounded-full " + ("bg-up" if r.status == "normal" else ("bg-warn" if r.status == "fallback" else "bg-down"))}
                                title={r.status}
                            ></span>
                            <span className={"num " + ("font-semibold" if active else "")}>{day_short(r.run_date)}</span>
                        </span>
                        <span className="num flex items-center gap-2 text-[12px]">
                            <span className={"w-5 text-right " + ("text-up" if buys > 0 else "text-faint")}>{("+" if buys > 0 else "") + str(buys)}</span>
                            <span className={"w-5 text-right " + ("text-down" if sells > 0 else "text-faint")}>{("-" if sells > 0 else "") + str(sells)}</span>
                            <span className="w-14 text-right text-faint">{count(r.trades, "fill")}</span>
                        </span>
                    </Link>
                </li>
            }}
        </ol>
        <p className="border-t border-line px-4 py-2.5 text-[11px] text-faint">Buys and adds, sells and trims, and orders that filled.</p>
    </Panel>
}

def:pub RunPage -> JsxElement {
    has run: RunData | None = None,
        runs: list[RunSummaryData] = [],
        loaded: bool = False,
        error: str = "";

    day: str = useParams()["day"] or "";

    async can with [day] entry {
        loaded = False;
        error = "";
        try {
            run = await get_run(day);
            if len(runs) == 0 {
                runs = await list_runs();
            }
        } except Exception as e {
            error = str(e);
        }
        loaded = True;
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if not loaded {
        return <Loading label="Loading the run"/>;
    }
    if run is None {
        if day {
            return <Empty title={"No run on " + day_long(day)}>
                The agent runs each trading morning. <Link to="/runs" className="text-accent hover:underline">Go to the latest run</Link>.
            </Empty>;
        }
        return <Empty title="No runs yet">The first morning run appears here once the forward test starts.</Empty>;
    }

    <div className="rise flex flex-col gap-6">
        <Header run={run}/>
        <Facts run={run}/>
        <CoverageTable run={run}/>
        <div className="grid grid-cols-1 items-start gap-6 lg:grid-cols-[minmax(0,1fr)_340px]">
            <Macro macro={run.macro}/>
            <RunList runs={runs} current={run.run_date}/>
        </div>
        <ActionLog lines={run.action_log}/>
    </div>
}

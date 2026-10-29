"""The Decision detail page (TDD §10), the product's hero: one ticker's trail through one run,
from the research and its sources, through every specialist's votes and the consensus, to the
Arbiter, the risk gate, and the orders. A strip at the top sums up each stage and jumps to it."""
import from "@jac/runtime" { Link, useParams }
import from "lucide-react" { Check, ChevronLeft, ChevronRight, ExternalLink, X }
import from dashboard.api { get_decision_trail }
import from dashboard.ui.DotPlot { DotPlot, ScoreScale }
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
    signed_money,
    signed_pct,
    stamp_et,
    title,
    tone
}
import from dashboard.ui.parts {
    ROW,
    TD,
    TD_TEXT,
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
    StatusBadge
}
# Aliased: the endpoint bridge declares the wire classes under their own names.
import from models.views {
    EvidenceView as EvidenceData,
    GateView as GateData,
    OrderView as OrderData,
    PositionView as PositionData,
    ResearchView as ResearchData,
    SampleView as SampleData,
    SpecialistView as SpecialistData,
    TrailView as TrailData
}

glob REASONS: dict[str, str] = {"screen": "From the screen", "held": "Held position", "wildcard": "Wildcard", "user_request": "User request"};
glob STANCES: dict[str, str] = {"STRONG_BUY": "Strong buy", "BUY": "Buy", "HOLD": "Hold", "SELL": "Sell", "STRONG_SELL": "Strong sell"};
glob STANCE_TONES: dict[str, str] = {"STRONG_BUY": "text-up", "BUY": "text-up", "HOLD": "text-muted", "SELL": "text-down", "STRONG_SELL": "text-down"};
glob VERDICTS: dict[str, str] = {"CONFIRM": "Confirmed the panel", "DOWNGRADE": "Downgraded the panel"};
glob LABEL: str = "text-[11px] font-medium uppercase tracking-[0.05em] text-faint";
# A warning set in a tinted band, in the pill's three strengths of one hue.
glob CALLOUT: str = "rounded-md border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-warn";
# The panel's columns: specialist, dot plot, mean, and the expand chevron.
glob GRID: str = "grid-cols-[1fr_auto] sm:grid-cols-[180px_1fr_72px_16px]";

def trail_to(day: str, ticker: str) -> str {
    return "/runs/" + day + "/" + ticker;
}

def StanceText(stance: str) -> JsxElement {
    <span className={"font-semibold " + STANCE_TONES.get(stance, "text-muted")}>{STANCES.get(stance, title(stance))}</span>
}

def SourceLink(e: EvidenceData) -> JsxElement {
    <a
        href={e.source_url}
        target="_blank"
        rel="noreferrer"
        className="group flex items-start gap-2 rounded-[4px] px-2 py-1.5 text-[12px] transition-colors duration-150 hover:bg-hover"
    >
        <ExternalLink size={12} className="mt-0.5 shrink-0 text-faint group-hover:text-accent"/>
        <span className="min-w-0">
            <span className="text-text">{e.claim}</span>
            <span className="block truncate text-[11px] text-faint">{e.host + (" · " + day_short(e.published) if e.published else "")}</span>
        </span>
    </a>
}

# --- Header and the trail strip ------------------------------------------------------------

def StepLink(to: str, label: str, forward: bool) -> JsxElement {
    base = "grid size-8 place-items-center ";
    icon = <ChevronRight size={16}/> if forward else <ChevronLeft size={16}/>;
    if not to {
        return <span className={base + "text-faint opacity-40"} aria-hidden="true">{icon}</span>;
    }
    <Link to={to} className={base + "press text-muted hover:bg-hover hover:text-text"} title={label} aria-label={label}>{icon}</Link>
}

def TickerNav(trail: TrailData) -> JsxElement {
    at = trail.tickers.index(trail.ticker) if trail.ticker in trail.tickers else -1;
    before = trail.tickers[at - 1] if at > 0 else "";
    after = trail.tickers[at + 1] if at >= 0 and at + 1 < len(trail.tickers) else "";
    <div className="flex shrink-0 items-center overflow-hidden rounded-md border border-line bg-panel">
        <StepLink to={trail_to(trail.run_date, before) if before else ""} label={"Previous: " + before} forward={False}/>
        <span className="num border-x border-line px-2.5 text-[12px] leading-8 text-muted">
            {(str(at + 1) + " of " + str(len(trail.tickers))) if at >= 0 else MISSING}
        </span>
        <StepLink to={trail_to(trail.run_date, after) if after else ""} label={"Next: " + after} forward={True}/>
    </div>
}

"""The entity header: a monogram tile, the ticker in the display face, and the decision with
its conviction at the right; the Arbiter's thesis reads under it as the page's summary."""
def Hero(trail: TrailData) -> JsxElement {
    d = trail.decision;
    <header className="flex flex-col gap-4">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div className="flex min-w-0 items-center gap-4">
                <span
                    className="display grid size-12 shrink-0 place-items-center rounded-md border border-accent/30 bg-accent/10 text-[26px] leading-none text-accent"
                    aria-hidden="true"
                >
                    {trail.ticker[0:1]}
                </span>
                <div className="min-w-0">
                    <div className="flex flex-wrap items-baseline gap-x-3">
                        <h1 className="display text-[36px] leading-10 text-text">{trail.ticker}</h1>
                        <span className="text-[13px] text-muted">{trail.sector}</span>
                    </div>
                    <div className="num flex flex-wrap items-baseline gap-x-2 text-[13px]">
                        <span className="font-medium text-text">{money(trail.last_close)}</span>
                        <span className="text-[11px] text-faint">{"close · " + REASONS.get(trail.reason, title(trail.reason)).lower()}</span>
                    </div>
                </div>
            </div>
            {if d is not None {
                <div className="grid shrink-0 grid-cols-[auto_auto] items-end justify-start gap-x-6 gap-y-0.5 sm:justify-items-end">
                    <Overline>Decision</Overline>
                    <Overline>Conviction</Overline>
                    <span className="pb-2"><ActionBadge action={d.action}/></span>
                    <span className="display text-[36px] leading-10 text-text">{num(d.conviction)}</span>
                </div>
            }}
        </div>
        {if d is not None and d.thesis {
            <p className="max-w-[680px] text-[15px] leading-6 text-pretty text-text">{d.thesis}</p>
        }}
    </header>
}

def Stage(n: int, target: str, label: str, value: str, sub: str = "", tone_class: str = "text-text") -> JsxElement {
    <a href={"#" + target} className="group flex min-w-0 flex-col bg-panel px-4 py-3 transition-colors duration-150 hover:bg-hover">
        <span className="flex items-center gap-2">
            <span className="font-mono text-[10px] font-medium text-accent">{"0" + str(n)}</span>
            <Overline className="truncate">{label}</Overline>
        </span>
        <span className={"num mt-1 truncate text-[15px] font-medium leading-5 " + tone_class}>{value}</span>
        <span className="num mt-0.5 truncate text-[11px] text-faint">{sub or "\u00a0"}</span>
    </a>
}

def TrailStrip(trail: TrailData) -> JsxElement {
    sources = 0;
    for r in trail.research {
        sources += len(r.evidence);
    }
    votes = 0;
    for s in trail.specialists {
        votes += len(s.samples);
    }
    c = trail.consensus;
    d = trail.decision;
    g = trail.gate;
    filled = 0;
    asked = 0;
    stops = 0;
    for o in trail.orders {
        if o.purpose == "stop" {
            stops += 1;
        } else {
            filled += o.filled_qty;
            asked += o.qty;
        }
    }
    <nav aria-label="Decision trail" className="grid grid-cols-2 gap-px overflow-hidden rounded-md border border-line bg-line sm:grid-cols-3 lg:grid-cols-6">
        <Stage n={1} target="research" label="Research" value={count(len(trail.research), "report")} sub={count(sources, "source")}/>
        <Stage n={2} target="panel" label="Panel" value={count(votes, "vote")} sub={count(len(trail.specialists), "specialist")}/>
        <Stage
            n={3}
            target="consensus"
            label="Consensus"
            value={signed(c.score) if c is not None else MISSING}
            sub={(pct(c.agreement, 0) + " agree") if c is not None else ""}
            tone_class={tone(c.score if c is not None else None)}
        />
        <Stage
            n={4}
            target="arbiter"
            label="Arbiter"
            value={(("No action" if d.action == "NO_ACTION" else d.action)) if d is not None else MISSING}
            sub={VERDICTS.get(d.arbiter_verdict, title(d.arbiter_verdict.lower())) if d is not None and d.arbiter_verdict else ("forced hold" if d is not None and d.forced_hold_reason else "")}
        />
        <Stage
            n={5}
            target="gate"
            label="Risk gate"
            value={title(g.outcome) if g is not None else "Not sent"}
            sub={(qty(g.approved_qty) + " of " + count(g.requested_qty, "share")) if g is not None else "no order to check"}
            tone_class={"text-down" if g is not None and g.outcome == "rejected" else "text-text"}
        />
        <Stage
            n={6}
            target="orders"
            label="Orders"
            value={(qty(filled) + " of " + qty(asked) + " filled") if asked > 0 else "None"}
            sub={", ".join([count(n, noun) for (n, noun) in [(len(trail.orders) - stops, "order"), (stops, "stop")] if n > 0])}
        />
    </nav>
}

# --- 1. Research -------------------------------------------------------------------------------

"""A label and its value as one row of a facts card."""
def Fact(label: str, children: any = None) -> JsxElement {
    <div className="flex items-baseline justify-between gap-4 border-b border-line/60 px-4 py-2.5 text-[13px] last:border-b-0">
        <span className="shrink-0 text-muted">{label}</span>
        <span className="num min-w-0 text-right font-medium">{children}</span>
    </div>
}

"""The side column's facts: the ticker's market numbers and why the run covered it."""
def TickerFacts(trail: TrailData) -> JsxElement {
    due = trail.sessions_to_earnings;
    earnings = "Not scheduled";
    if due is not None {
        earnings = "in " + count(due, "session");
        if due == 0 {
            earnings = "today";
        }
    }
    <Panel title="Ticker" aside={<span>{"As of " + day_short(trail.run_date)}</span>} pad={False}>
        <Fact label="Last close">{money(trail.last_close)}</Fact>
        <Fact label="ATR (14)">{money(trail.atr_14)}</Fact>
        <Fact label="20-day vol">{pct(trail.realized_vol_20, 1)}</Fact>
        <Fact label="20-day volume">{compact(trail.volume_20)}</Fact>
        <Fact label="Earnings">{earnings}</Fact>
        <Fact label="Covered">{REASONS.get(trail.reason, title(trail.reason))}</Fact>
        {if trail.screen_score is not None {
            <Fact label="Screen score">{num(trail.screen_score)}</Fact>
        }}
        {if trail.reason_note and trail.reason != "held" {
            <p className="border-t border-line/60 px-4 py-2.5 text-[12px] text-muted">{trail.reason_note}</p>
        }}
    </Panel>
}

def PositionFacts(p: PositionData) -> JsxElement {
    closed = bool(p.closed_at);
    <Panel title={"Position " + ("closed" if closed else "open")} pad={False}>
        <Fact label="Shares">{qty(p.entry_qty if closed else p.qty)}</Fact>
        <Fact label="Avg cost">{money(p.avg_entry_price)}</Fact>
        <Fact label={"Exit" if closed else "Last"}>{money(p.exit_price if closed else p.last_price)}</Fact>
        <Fact label={"Realized" if closed else "Unrealized"}><span className={tone(p.pnl)}>{signed_money(p.pnl)}</span></Fact>
        <Fact label="Return"><span className={tone(p.pnl_pct)}>{signed_pct(p.pnl_pct)}</span></Fact>
    </Panel>
}

def Backdrop(trail: TrailData) -> JsxElement {
    <Panel title="Market backdrop">
        <p className="text-[13px] leading-relaxed text-muted">{trail.macro.summary if trail.macro is not None else "No macro brief was recorded."}</p>
        <Link to={"/runs/" + trail.run_date} className="mt-2 inline-block text-[12px] font-medium text-accent hover:underline">The run's macro brief</Link>
    </Panel>
}

def ReportRow(r: ResearchData) -> JsxElement {
    has open: bool = False;

    <li className="flex flex-col gap-2 border-b border-line/60 px-4 py-3.5 last:border-b-0">
        <div className="flex items-center justify-between gap-3">
            <Overline>{title(r.domain) + (" follow-up" if r.followup_question else "")}</Overline>
            <span className="num text-[12px]"><StanceText stance={r.view}/><span className="text-faint">{" · " + pct(r.confidence, 0)}</span></span>
        </div>
        {if r.followup_question {
            <p className="text-[12px] italic text-muted">{"Asked: " + r.followup_question}</p>
        }}
        <p className="max-w-[720px] text-[13px] leading-relaxed text-text">{r.summary}</p>
        {if len(r.risks) > 0 or len(r.data_gaps) > 0 {
            <ul className="flex flex-col gap-1 text-[12px] text-muted">
                {for risk in r.risks {
                    <li key={"r" + risk} className="flex gap-2"><span className="mt-[7px] size-1 shrink-0 rounded-full bg-warn" aria-hidden="true"></span><span>{risk}</span></li>
                }}
                {for gap in r.data_gaps {
                    <li key={"g" + gap} className="flex gap-2"><span className="mt-[6px] size-1.5 shrink-0 rounded-full border border-faint" aria-hidden="true"></span><span>{"Data gap: " + gap}</span></li>
                }}
            </ul>
        }}
        {if len(r.evidence) > 0 {
            <button
                type="button"
                onClick={lambda { open = not open; }}
                aria-expanded={open}
                className="press inline-flex items-center gap-1 self-start text-[12px] font-medium text-accent hover:underline"
            >
                <ChevronRight size={13} className={"transition-[rotate] duration-150 ease-out " + ("rotate-90" if open else "")}/>
                {("Hide " if open else "Show ") + count(len(r.evidence), "source")}
            </button>
        }}
        {if open {
            <div className="-mx-2 flex flex-col">
                {for (i, e) in enumerate(r.evidence) {
                    <SourceLink key={str(i)} e={e}/>
                }}
            </div>
        }}
    </li>
}

def Research(trail: TrailData) -> JsxElement {
    <Panel anchor="research" title="1 · Research" aside={<span>What the agents read</span>} pad={False}>
        {if len(trail.fetch_errors) > 0 {
            <p className={CALLOUT + " mx-4 mt-4"}>{"Some data could not be fetched: " + "; ".join(trail.fetch_errors)}</p>
        }}
        {if len(trail.research) == 0 {
            <p className="px-4 py-6 text-[13px] text-muted">No research was recorded for this ticker.</p>
        } else {
            <ul>
                {for (i, r) in enumerate(trail.research) {
                    <ReportRow key={r.domain + str(i)} r={r}/>
                }}
            </ul>
        }}
    </Panel>
}

# --- 2. Panel -------------------------------------------------------------------------------

def Outcome(s: SampleData) -> JsxElement {
    if s.hit is None {
        return <span className="text-[11px] text-faint">{"Scored after " + count(s.horizon_days, "session")}</span>;
    }
    <span className={"num text-[11px] " + ("text-up" if s.hit else "text-down")}>
        {("Hit" if s.hit else "Miss") + ", " + signed_pct(s.excess_return) + " vs SPY"}
    </span>
}

def SampleRow(s: SampleData) -> JsxElement {
    <li className="flex flex-col gap-1.5 border-t border-line py-2.5 first:border-t-0">
        <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 text-[12px]">
            <span>
                <span className="num text-faint">{"#" + str(s.sample + 1) + "  "}</span>
                <StanceText stance={s.stance}/>
                <span className="num text-faint">{" · " + pct(s.confidence, 0) + " sure · " + count(s.horizon_days, "session") + " · signed " + signed(s.signed)}</span>
            </span>
            <Outcome s={s}/>
        </div>
        <p className="text-[13px] leading-relaxed text-muted">{s.rationale}</p>
        {if len(s.sources) > 0 {
            <div className="-mx-2 flex flex-col">
                {for (i, e) in enumerate(s.sources) {
                    <SourceLink key={str(i)} e={e}/>
                }}
            </div>
        }}
    </li>
}

def SpecialistRow(s: SpecialistData) -> JsxElement {
    has open: bool = False;

    <li className="border-b border-line/60 last:border-b-0">
        <button
            type="button"
            onClick={lambda { open = not open; }}
            aria-expanded={open}
            className={"grid w-full items-center gap-x-4 gap-y-1 px-4 py-3 text-left transition-colors duration-150 hover:bg-hover " + GRID}
        >
            <span className="flex items-baseline gap-2">
                <span className="text-[13px] font-medium">{title(s.specialist)}</span>
                <span className="num text-[11px] text-faint">{("weight " + num(s.weight)) if s.weight is not None else ""}</span>
            </span>
            <span className="order-3 col-span-2 sm:order-none sm:col-span-1">
                <DotPlot values={[x.signed for x in s.samples]} mean={s.score}/>
            </span>
            <span className={"num text-right text-[13px] font-semibold " + tone(s.score)}>{signed(s.score)}</span>
            <ChevronRight size={14} className={"hidden text-faint transition-[rotate] duration-150 ease-out sm:block " + ("rotate-90" if open else "")}/>
        </button>
        {if open {
            <ol className="bg-panel-2/50 px-4 pb-1">
                {for x in s.samples {
                    <SampleRow key={str(x.sample)} s={x}/>
                }}
            </ol>
        }}
    </li>
}

def PanelVotes(trail: TrailData) -> JsxElement {
    <Panel anchor="panel" title="2 · Panel" aside={<span>Each dot is one sample; the bar is the mean</span>} pad={False}>
        <div>
            {if len(trail.specialists) == 0 {
                <p className="px-4 py-6 text-[13px] text-muted">The panel did not vote on this ticker.</p>
            } else {
                <div className={"hidden items-center gap-x-4 border-b border-line bg-panel-2 px-4 py-2 sm:grid " + GRID}>
                    <span className={LABEL + " text-muted"}>Specialist</span>
                    <span className="num mx-1.5 flex justify-between text-[10px] text-faint">
                        <span>-1 sell</span><span>0</span><span>+1 buy</span>
                    </span>
                    <span className={LABEL + " text-right text-muted"}>Mean</span>
                    <span></span>
                </div>
                <ul>
                    {for s in trail.specialists {
                        <SpecialistRow key={s.specialist} s={s}/>
                    }}
                </ul>
            }}
        </div>
    </Panel>
}

# --- 3. Consensus and 4. Arbiter ---------------------------------------------------------------

def Consensus(trail: TrailData) -> JsxElement {
    c = trail.consensus;
    <Panel anchor="consensus" title="3 · Consensus" className="h-full">
        <div>
            {if c is None {
                <p className="text-[13px] text-muted">No consensus was reached, so the ticker was held without a panel decision.</p>
            } else {
                <div className="flex flex-col gap-3">
                    <div className="flex items-start justify-between gap-4">
                        <div>
                            <div className={LABEL}>Weighted score</div>
                            <div className={"display mt-0.5 text-[36px] leading-10 " + tone(c.score)}>{signed(c.score)}</div>
                        </div>
                        <div className="text-right">
                            <div className={LABEL}>Interval</div>
                            <div className="num mt-1 text-[13px] font-medium">{signed(c.ci_low) + " to " + signed(c.ci_high)}</div>
                        </div>
                    </div>
                    <ScoreScale score={c.score} low={c.ci_low} high={c.ci_high}/>
                    <div className="border-t border-line pt-1">
                        <Field label="Agreement">{pct(c.agreement, 0)}</Field>
                        <Field label="Samples">{str(c.samples_used) + " used" + ((", " + str(c.samples_dropped) + " dropped") if c.samples_dropped else "")}</Field>
                        <Field label="Draft action"><ActionBadge action={c.draft_action}/></Field>
                    </div>
                </div>
            }}
        </div>
    </Panel>
}

def Arbiter(trail: TrailData) -> JsxElement {
    d = trail.decision;
    <Panel anchor="arbiter" title="4 · Arbiter" className="h-full">
        <div>
            {if d is None {
                <p className="text-[13px] text-muted">No decision was recorded.</p>
            } else {
                <div className="flex flex-col gap-3">
                    <div className="flex flex-wrap items-center gap-2">
                        <ActionBadge action={d.action}/>
                        <span className="text-[12px] text-muted">
                            {VERDICTS.get(d.arbiter_verdict, title(d.arbiter_verdict.lower())) if d.arbiter_verdict else ""}
                        </span>
                    </div>
                    {if d.downgrade_reason {
                        <p className={CALLOUT}>{"Downgraded: " + d.downgrade_reason}</p>
                    }}
                    {if d.forced_hold_reason {
                        <p className={CALLOUT}>{"Forced hold: " + d.forced_hold_reason}</p>
                    }}
                    {if len(d.risks) > 0 {
                        <div>
                            <div className={LABEL}>Key risks</div>
                            <ul className="mt-1.5 flex flex-col gap-1 text-[13px]">
                                {for risk in d.risks {
                                    <li key={risk} className="flex gap-2"><span className="mt-[8px] size-1 shrink-0 rounded-full bg-warn" aria-hidden="true"></span><span>{risk}</span></li>
                                }}
                            </ul>
                        </div>
                    }}
                    <div className="border-t border-line pt-1">
                        <Field label="Exit if">{d.exit_condition or MISSING}</Field>
                        <Field label="Time stop">{day_long(d.time_stop) if d.time_stop else MISSING}</Field>
                    </div>
                    <p className="truncate font-mono text-[11px] text-faint" title={d.model}>{"Decided by " + (d.model or MISSING)}</p>
                </div>
            }}
        </div>
    </Panel>
}

# --- 5. Risk gate ------------------------------------------------------------------------------

def RuleRow(rule: str, passed: bool, detail: str, before: int, after: int) -> JsxElement {
    <tr className={ROW}>
        <td className={TD + " w-8 pr-0"}>
            {<Check size={14} className="text-up"/> if passed else <X size={14} className="text-down"/>}
        </td>
        <td className={TD + " font-medium"}>{title(rule)}</td>
        <td className={TD_TEXT + " text-muted"}>{detail or MISSING}</td>
        <td className={TD_NUM + (" text-warn" if after != before else " text-muted")}>
            {(qty(before) + " → " + qty(after)) if after != before else qty(after)}
        </td>
    </tr>
}

def GateFigure(label: str, value: str) -> JsxElement {
    <div className="min-w-0 bg-panel px-4 py-3">
        <Overline>{label}</Overline>
        <div className="num mt-1 truncate text-[15px] font-medium leading-5">{value}</div>
    </div>
}

def Gate(g: GateData | None) -> JsxElement {
    aside = <StatusBadge status={g.outcome}/> if g is not None else None;
    <Panel anchor="gate" title="5 · Risk gate" aside={aside} pad={False}>
        <div>
            {if g is None {
                <p className="px-4 py-6 text-[13px] text-muted">No order went to the risk gate: the decision held, or sizing left no shares to trade.</p>
            } else {
                <div>
                    <div className="grid grid-cols-2 gap-px border-b border-line bg-line sm:grid-cols-4">
                        <GateFigure label="Order" value={g.side.upper() + " · " + title(g.purpose)}/>
                        <GateFigure label="Shares" value={qty(g.approved_qty) + " of " + qty(g.requested_qty)}/>
                        <GateFigure label="Price" value={money(g.price)}/>
                        <GateFigure label="Stop distance" value={money(g.stop_distance)}/>
                    </div>
                    <div className="scroll-x">
                        <table className="w-full">
                            <thead>
                                <tr>
                                    <th className={TH + " w-8"}></th>
                                    <th className={TH}>Rule</th>
                                    <th className={TH}>Detail</th>
                                    <th className={TH_NUM}>Shares</th>
                                </tr>
                            </thead>
                            <tbody>
                                {for r in g.rules {
                                    <RuleRow key={r.rule} rule={r.rule} passed={r.passed} detail={r.detail} before={r.qty_before} after={r.qty_after}/>
                                }}
                            </tbody>
                        </table>
                    </div>
                    <p className="num border-t border-line px-4 py-2 text-[11px] text-faint">{"Checked " + stamp_et(g.checked_at) + " · gate " + (g.gate_version or MISSING)}</p>
                </div>
            }}
        </div>
    </Panel>
}

# --- 6. Orders and the position ---------------------------------------------------------------

def OrdersTable(orders: list[OrderData]) -> JsxElement {
    <div className="scroll-x">
        <table className="w-full min-w-[760px]">
            <thead>
                <tr>
                    <th className={TH}>Submitted</th>
                    <th className={TH}>Order</th>
                    <th className={TH_NUM}>Price</th>
                    <th className={TH_NUM}>Filled</th>
                    <th className={TH}>Fills</th>
                    <th className={TH}>Status</th>
                </tr>
            </thead>
            <tbody>
                {for o in orders {
                    <tr key={o.client_order_id} className={ROW}>
                        <td className={TD + " num text-muted"}>{stamp_et(o.submitted_at)}</td>
                        <td className={TD}>
                            <span className={"font-semibold uppercase " + ("text-up" if o.side == "buy" else "text-down")}>{o.side}</span>
                            <span className="text-muted">{" " + title(o.purpose) + " · " + title(o.order_type) + " " + o.time_in_force.upper()}</span>
                            <div className="font-mono text-[10px] text-faint">{o.client_order_id}</div>
                        </td>
                        <td className={TD_NUM}>{money(o.limit_price if o.limit_price is not None else o.stop_price)}</td>
                        <td className={TD_NUM}>{qty(o.filled_qty) + " / " + qty(o.qty)}</td>
                        <td className={TD + " num text-[12px] text-muted"}>
                            {if len(o.fills) == 0 {
                                <span className="text-faint">-</span>
                            }}
                            {for (i, f) in enumerate(o.fills) {
                                <div key={str(i)}>{qty(f.qty) + " @ " + money(f.price) + ", " + stamp_et(f.filled_at)}</div>
                            }}
                        </td>
                        <td className={TD} title={o.reject_reason}><StatusBadge status={o.status}/></td>
                    </tr>
                }}
            </tbody>
        </table>
    </div>
}

def Orders(trail: TrailData) -> JsxElement {
    <Panel anchor="orders" title="6 · Orders" pad={False}>
        <div>
            {if len(trail.orders) == 0 {
                <p className="px-4 py-6 text-[13px] text-muted">{"No orders were placed." if trail.mode == "auto" else "Insight mode: this decision was published as a card, not traded."}</p>
            } else {
                <OrdersTable orders={trail.orders}/>
            }}
        </div>
    </Panel>
}

def:pub DecisionPage -> JsxElement {
    has trail: TrailData | None = None,
        loaded: bool = False,
        error: str = "";

    params = useParams();
    day: str = params["day"] or "";
    ticker: str = params["ticker"] or "";

    async can with (day, ticker) entry {
        loaded = False;
        error = "";
        try {
            trail = await get_decision_trail(day, ticker);
        } except Exception as e {
            error = str(e);
        }
        loaded = True;
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if not loaded {
        return <Loading label="Loading the decision trail"/>;
    }
    if trail is None {
        return <Empty title={ticker.upper() + " was not covered on " + day_long(day)}>
            <Link to={"/runs/" + day} className="text-accent hover:underline">See what that run covered</Link>.
        </Empty>;
    }

    <div className="rise flex flex-col gap-6">
        <div className="flex items-center justify-between gap-3">
            <nav aria-label="Breadcrumb" className="flex min-w-0 items-center gap-1.5 text-[13px] text-muted">
                <Link to="/runs" className="hover:text-text">Runs</Link>
                <ChevronRight size={14} className="shrink-0 text-faint"/>
                <Link to={"/runs/" + trail.run_date} className="num truncate hover:text-text">{day_long(trail.run_date)}</Link>
                <ChevronRight size={14} className="shrink-0 text-faint"/>
                <span className="font-medium text-text">{trail.ticker}</span>
            </nav>
            <TickerNav trail={trail}/>
        </div>
        <Hero trail={trail}/>
        <TrailStrip trail={trail}/>
        <div className="grid grid-cols-1 items-start gap-6 lg:grid-cols-[320px_minmax(0,1fr)]">
            <aside className="order-last flex flex-col gap-6 lg:order-first">
                <TickerFacts trail={trail}/>
                {if trail.position is not None {
                    <PositionFacts p={trail.position}/>
                }}
                <Backdrop trail={trail}/>
            </aside>
            <div className="flex min-w-0 flex-col gap-6">
                <Research trail={trail}/>
                <PanelVotes trail={trail}/>
                <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
                    <Consensus trail={trail}/>
                    <Arbiter trail={trail}/>
                </div>
                <Gate g={trail.gate}/>
                <Orders trail={trail}/>
            </div>
        </div>
    </div>
}

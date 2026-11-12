"""The Results page (TDD §13, metrics): how the agent did in the forward test against both
baselines, and where the result came from (the screen, the specialists, the Arbiter), with how
reliably it ran. It reads the evaluation the evening review stored (analysis/evaluation.jac), so
every figure is as of the last close, every interval is 95%, and the snapshot ID it shows is the one
the final report prints when it was built from the same evaluation. A figure with too few
observations behind it says so (dashboard/ui/evidence.jac) instead of showing a number."""
import from "@jac/runtime" { Link }
import from dashboard.ui.rpc { get_evaluation }
import from dashboard.ui.format { MISSING, count, day_long, day_short, num, pct, signed, signed_pct, stamp_et, title, tone }
import from dashboard.ui.parts { Empty, ErrorBox, Loading, Overline, PILL_BASE, Panel, ROW, TD, TD_NUM, TH, TH_NUM, TONE_DOWN, TONE_QUIET, TONE_UP }
import from dashboard.ui.evidence { Provenance, Thin, enough, sessions_needed, votes_needed }
# Aliased: the endpoint bridge declares the wire classes under their own names.
import from models.evaluation {
    ArbiterResult as ArbiterData,
    Comparison as ComparisonData,
    Estimate as EstimateData,
    Evaluation as EvaluationData,
    Operations as OperationsData,
    Reliability as ReliabilityData,
    ScreenResult as ScreenData,
    SeriesResult as SeriesData,
    SpecialistCalibration as CalibrationData
}

glob VERDICTS: dict[str, tuple[str, str]] = {
    "ahead": ("Ahead", TONE_UP),
    "behind": ("Behind", TONE_DOWN),
    "helped": ("Helped", TONE_UP),
    "hurt": ("Hurt", TONE_DOWN),
    "unclear": ("Not clear yet", TONE_QUIET),
    "no data": ("No data yet", TONE_QUIET),
    "too few": ("Not enough data", TONE_QUIET)
};
glob SHORT_LABELS: dict[str, str] = {"team": "Your agent", "equal_weight": "Equal-weight", "spy": "SPY"};
# How a comparison names its baseline mid-sentence.
glob AGAINST: dict[str, str] = {"equal_weight": "the equal-weight shortlist", "spy": "SPY buy-and-hold"};

"""An estimate as a signed percentage, with its interval when it has one."""
def ranged_pct(e: EstimateData | None, digits: int = 2) -> str {
    if e is None or e.value is None {
        return MISSING;
    }
    if e.lo is None or e.hi is None {
        return signed_pct(e.value, digits);
    }
    return signed_pct(e.value, digits) + " (" + signed_pct(e.lo, digits) + " to " + signed_pct(e.hi, digits) + ")";
}

def ranged_num(e: EstimateData | None) -> str {
    if e is None or e.value is None {
        return MISSING;
    }
    if e.lo is None or e.hi is None {
        return signed(e.value, 2);
    }
    return signed(e.value, 2) + " (" + signed(e.lo, 2) + " to " + signed(e.hi, 2) + ")";
}

def Verdict(word: str) -> JsxElement {
    (label, tone_) = VERDICTS.get(word, (title(word), TONE_QUIET));
    <span className={PILL_BASE + " " + tone_}>{label}</span>
}

"""The interval of `e` alone, as "(-0.40% to +1.10%)"."""
def interval_pct(e: EstimateData) -> str {
    return "(" + signed_pct(e.lo) + " to " + signed_pct(e.hi) + ")" if e.lo is not None and e.hi is not None else MISSING;
}

"""The system against one baseline, always with the sessions it rests on: its excess return with
its interval and Sharpe gap, and the verdict, or "not enough data" below the sessions an interval
needs."""
def ComparisonRow(c: ComparisonData) -> JsxElement {
    ready = enough(c.sessions, sessions_needed());
    <div className="flex flex-col gap-2 border-t border-line px-4 py-4 first:border-t-0 sm:flex-row sm:items-center sm:gap-6">
        <div className="min-w-0 sm:w-56">
            <div className="text-[13px] text-muted">{"Against " + AGAINST.get(c.baseline, c.label)}</div>
            {if ready {
                <div className={"num mt-1 text-[22px] font-medium leading-7 " + tone(c.excess_return.value)}>{signed_pct(c.excess_return.value)}</div>
            } else {
                <Thin have={c.sessions} need={sessions_needed()} unit="matched sessions" className="num mt-1 block text-[13px] leading-7"/>
            }}
        </div>
        <dl className="num grid min-w-0 flex-1 grid-cols-1 gap-1 text-[12px] text-muted sm:grid-cols-3">
            <div><dt className="inline">Matched sessions </dt><dd className="inline text-text">{str(c.sessions)}</dd></div>
            <div><dt className="inline">Interval </dt><dd className="inline text-text">{interval_pct(c.excess_return) if ready else MISSING}</dd></div>
            <div><dt className="inline">Sharpe gap </dt><dd className="inline text-text">{ranged_num(c.sharpe_difference) if ready else MISSING}</dd></div>
        </dl>
        <div className="shrink-0"><Verdict word={c.verdict if ready else "too few"}/></div>
    </div>
}

def SeriesTable(series: list[SeriesData]) -> JsxElement {
    <div className="scroll-x border-t border-line">
        <table className="w-full max-md:[&_td]:px-2 max-md:[&_th]:px-2">
            <thead>
                <tr>
                    <th className={TH}></th>
                    {for s in series { <th key={s.key} className={TH_NUM + " max-sm:whitespace-normal"}>{SHORT_LABELS.get(s.key, s.label)}</th> }}
                </tr>
            </thead>
            <tbody>
                <tr className={ROW}>
                    <td className={TD + " text-muted max-sm:whitespace-normal"}>Total return</td>
                    {for s in series { <td key={s.key} className={TD_NUM + " " + tone(s.total_return)}>{signed_pct(s.total_return)}</td> }}
                </tr>
                <tr className={ROW}>
                    <td className={TD + " text-muted max-sm:whitespace-normal"}>Sharpe</td>
                    {for s in series { <td key={s.key} className={TD_NUM}>{num(s.sharpe, 2)}</td> }}
                </tr>
                <tr className={ROW}>
                    <td className={TD + " text-muted max-sm:whitespace-normal"}>Max drawdown</td>
                    {for s in series { <td key={s.key} className={TD_NUM}>{pct(s.max_drawdown)}</td> }}
                </tr>
            </tbody>
        </table>
    </div>
}

def Baselines(e: EvaluationData) -> JsxElement {
    <Panel title="Against the baselines" aside={<span className="num">{count(e.sessions, "session") + " since " + day_short(e.start_day)}</span>} pad={False}>
        {if len(e.comparisons) == 0 {
            <p className="px-4 py-4 text-[13px] text-muted">The baselines start with the forward test. Until then there is nothing to compare.</p>
        } else {
            <div>{for c in e.comparisons { <ComparisonRow key={c.baseline} c={c}/> }}</div>
        }}
        {if len(e.series) > 0 { <SeriesTable series={e.series}/> }}
        <p className="border-t border-line px-4 py-2.5 text-[12px] text-faint">
            Excess return is your agent's total return minus the baseline's over the sessions both marked. A result is clear only when its interval leaves out zero.
        </p>
    </Panel>
}

def Figure(label: str, value: str, sub: str = "", tone_: str = "text-text") -> JsxElement {
    <div className="min-w-0">
        <Overline className="truncate">{label}</Overline>
        <div className={"num mt-1.5 text-[20px] font-medium leading-7 " + tone_}>{value}</div>
        {if sub { <div className="num mt-0.5 text-[12px] text-muted">{sub}</div> }}
    </div>
}

def Screen(s: ScreenData) -> JsxElement {
    <Panel title="Screen" aside={count(s.runs, "run") + " scored"}>
        {if s.runs == 0 {
            <p className="text-[13px] text-muted">A run's screen is scored ten sessions after it, against the rest of the S&P 500.</p>
        } elif not enough(s.runs, sessions_needed()) {
            <p className="num text-[13px] text-muted"><Thin have={s.runs} need={sessions_needed()} unit="scored runs" className="block text-text"/>A run's screen is scored ten sessions after it, against the rest of the S&P 500.</p>
        } else {
            <div className="flex flex-col gap-4">
                <div className="grid grid-cols-2 gap-4">
                    <Figure label="Shortlist" value={signed_pct(s.picks_excess)} sub="vs SPY, 10 sessions" tone_={tone(s.picks_excess)}/>
                    <Figure label="Rest of index" value={signed_pct(s.rest_excess)} sub="vs SPY, 10 sessions" tone_={tone(s.rest_excess)}/>
                </div>
                <p className="num text-[13px] text-muted">
                    {"Spread " + ranged_pct(s.spread) + ". The shortlist beat the rest in " + str(s.positive_runs) + " of " + count(s.runs, "run") + "."}
                </p>
            </div>
        }}
    </Panel>
}

def Arbiter(a: ArbiterData) -> JsxElement {
    ready = enough(a.blocked, sessions_needed());
    <Panel title="Arbiter" aside={<Verdict word={a.verdict if ready else "too few"}/>}>
        {if a.blocked == 0 and a.confirmed == 0 {
            <p className="text-[13px] text-muted">No buy the Arbiter reviewed has been scored yet. A decision is scored ten sessions after its run.</p>
        } elif not ready {
            <p className="num text-[13px] text-muted"><Thin have={a.blocked} need={sessions_needed()} unit="scored blocked buys" className="block text-text"/>{"Blocking helps when the blocked buys lag SPY. " + str(a.confirmed) + " confirmed buys are scored so far."}</p>
        } else {
            <div className="flex flex-col gap-4">
                <div className="grid grid-cols-2 gap-4">
                    <Figure label={"Blocked · " + str(a.blocked)} value={signed_pct(a.blocked_excess.value)} sub="if taken, vs SPY" tone_={tone(a.blocked_excess.value)}/>
                    <Figure label={"Confirmed · " + str(a.confirmed)} value={signed_pct(a.confirmed_excess.value)} sub="vs SPY" tone_={tone(a.confirmed_excess.value)}/>
                </div>
                <p className="num text-[13px] text-muted">
                    {"Blocking helps when the blocked buys lag SPY. Their mean: " + ranged_pct(a.blocked_excess) + "."}
                </p>
            </div>
        }}
    </Panel>
}

def gap_text(c: CalibrationData) -> str {
    if c.gap is None {
        return MISSING;
    }
    return signed(c.gap * 100.0, 0) + " pts";
}

def Specialists(rows: list[CalibrationData]) -> JsxElement {
    <Panel title="Specialist calibration" anchor="calibration" aside={<Link to="/app/specialists" className="text-accent hover:underline">Recent votes</Link>} pad={False}>
        {if len(rows) == 0 {
            <p className="px-4 py-4 text-[13px] text-muted">No vote has been scored yet. Votes are scored when their window closes, usually ten sessions after the run.</p>
        } else {
            <div className="scroll-x">
                <table className="w-full max-md:[&_td]:px-2 max-md:[&_th]:px-2">
                    <thead>
                        <tr>
                            <th className={TH}>Specialist</th>
                            <th className={TH_NUM + " max-sm:hidden"}>Votes</th>
                            <th className={TH_NUM}>Confidence</th>
                            <th className={TH_NUM}>Hit rate</th>
                            <th className={TH_NUM}>Gap</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for c in rows {
                            <tr key={c.specialist} className={ROW}>
                                <td className={TD}>
                                    {title(c.specialist)}
                                    <span className="num block text-[11px] text-faint sm:hidden">{count(c.votes, "vote")}</span>
                                </td>
                                <td className={TD_NUM + " max-sm:hidden"}>{str(c.votes)}</td>
                                <td className={TD_NUM}>{pct(c.confidence, 0)}</td>
                                {if enough(c.votes, votes_needed()) {
                                    <td className={TD_NUM}>
                                        {pct(c.hit_rate.value, 0)}
                                        {if c.hit_rate.lo is not None {
                                            <span className="text-faint max-sm:block max-sm:text-[11px]">{" (" + pct(c.hit_rate.lo, 0) + " to " + pct(c.hit_rate.hi, 0) + ")"}</span>
                                        }}
                                    </td>
                                } else {
                                    <td className={TD_NUM + " whitespace-normal"}><Thin have={c.votes} need={votes_needed()} unit="scored votes" className="text-[12px]"/></td>
                                }}
                                <td className={TD_NUM + (" text-up" if c.within_target else (" text-down" if c.within_target is not None else ""))}>{gap_text(c) if enough(c.votes, votes_needed()) else MISSING}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
        }}
        <p className="border-t border-line px-4 py-2.5 text-[12px] text-faint">
            {"A well-calibrated specialist is right about as often as it says: the gap between its hit rate and its mean confidence stays within 10 points. Only directional votes count, and a hit rate shows from " + str(votes_needed()) + " scored votes."}
        </p>
    </Panel>
}

def minutes_text(m: float | None) -> str {
    if m is None {
        return MISSING;
    }
    return str(int(round(m))) + " min";
}

def Operations(r: ReliabilityData, o: OperationsData) -> JsxElement {
    <Panel title="Reliability">
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Figure label="Complete runs" value={pct(r.share, 0)} sub={str(r.complete) + " of " + count(r.sessions, "session")} tone_={"text-up" if r.share is not None and r.share >= 0.98 else "text-text"}/>
            <Figure label="Gate bypasses" value={str(o.bypasses)} sub="orders outside the gate" tone_={"text-up" if o.bypasses == 0 else "text-down"}/>
            <Figure label="Run time" value={minutes_text(o.latency_median_minutes)} sub={"median, longest " + minutes_text(o.latency_max_minutes)}/>
            <Figure label="Model requests" value={num(o.requests_per_run, 0)} sub={("per run, peak day " + str(o.peak_daily_requests) + " of " + str(o.daily_cap)) if o.peak_daily_requests > 0 else ("per run, at most " + str(o.requests_max_run))}/>
        </div>
        {if len(r.missed) > 0 or len(r.incomplete) > 0 {
            <ul className="num mt-4 flex flex-col gap-1 border-t border-line pt-3 text-[12px] text-muted">
                {for d in r.missed { <li key={"m" + d}>{day_long(d) + ": no run"}</li> }}
                {for line in r.incomplete { <li key={"i" + line}>{line}</li> }}
            </ul>
        }}
    </Panel>
}

def:pub ResultsPage -> JsxElement {
    has found: EvaluationData | None = None,
        loaded: bool = False,
        error: str = "";

    async can with entry {
        try {
            found = await get_evaluation();
        } except Exception as e {
            error = str(e);
        }
        loaded = True;
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if not loaded {
        return <Loading label="Loading results"/>;
    }
    if found is None or not found.start_day {
        return <Empty title="No results yet">Results appear after the evening review that follows your agent's first run.</Empty>;
    }

    <div className="rise flex flex-col gap-6">
        <header className="flex flex-col gap-2">
            <Overline className="num">{"Forward test · through " + day_long(found.last_day) + " close"}</Overline>
            <h1 className="display text-[36px] leading-10 text-text">Results</h1>
            <div className="num flex flex-wrap items-center gap-2 text-[12px] text-faint">
                <Provenance kind={"demo" if found.demo else "live"}/>
                {if found.snapshot { <span>{"Snapshot " + found.snapshot + ", stored " + stamp_et(found.as_of)}</span> }}
            </div>
            <p className="max-w-[640px] text-[13px] leading-5 text-muted">
                How your agent did against SPY and an equal-weight basket of the same shortlist, and where the result came from.
                Intervals are 95%; with a few weeks of data most will be wide.
            </p>
        </header>
        <Baselines e={found}/>
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Screen s={found.screen}/>
            <Arbiter a={found.arbiter}/>
        </div>
        <Specialists rows={found.specialists}/>
        <Operations r={found.reliability} o={found.operations}/>
        <p className="num text-[12px] text-faint">{"Updated " + stamp_et(found.as_of) + (". The final report built from this evaluation prints snapshot " + found.snapshot + "." if found.snapshot else ".")}</p>
    </div>
}

"""The Policy page: when to buy, sell, trim, and hold, as numbers with hard limits and as rules
over a fixed set of metrics, tried against the latest morning run as they change.

The policy here is the one this account's agent runs on, from its next morning run. Every draft
goes to the server for its replay, its words, and its limits, so what this page says is what a
save would do."""
import from "@jac/runtime" { Link, jacIsLoggedIn }
import from dashboard.ui.retry { call_function }
import from "lucide-react" { ChevronLeft, ChevronRight, MessageCircle, Pause, Play, Plus, RotateCcw, Trash2 }
import from "react" { useEffect }
import from dashboard.PolicyChat { PolicyChat }
import from dashboard.ui.format { day_long, day_short, num, signed, stamp_et }
import from dashboard.ui.parts { ActionBadge, ErrorBox, Loading, Overline, PILL_BASE, Panel, TAP_BUTTON, TAP_INPUT, TAP_QUIET, TONE_ACCENT, TONE_QUIET, TONE_WARN }
import from models.policy { Knob as KnobData, Metric as MetricData, PolicyRule as RuleData }
import from models.policy_views {
    OpView as OpData,
    PolicyCatalog as CatalogData,
    PolicyDoc as DocData,
    PolicySaveReply as SaveReply,
    ReplayRow as RowData,
    VersionView as VersionData
}

glob PREVIEW_DELAY_MS: int = 250;
glob SOURCES: dict[str, str] = {"form": "Edited in the form", "chat": "From the assistant", "restore": "Restored"};

def contract(name: str) -> dict[str, str] {
    return {"contract": "[\"trading-agent\",\"policy/api.jac\",\"func\",\"" + name + "\"]"};
}

"""A draft is a plain object once edited, so it goes over the runtime's RPC helper as JSON: the
typed bridge expects a wire class instance. The server rebuilds and checks it either way."""
async def preview_draft(policy: any, run_date: str) -> any {
    if not jacIsLoggedIn() { return None; }
    return await call_function("preview_policy", {"policy": policy, "run_date": run_date}, contract("preview_policy"));
}

"""A copy of `thing` with `field` set. A dict literal's bare name would be taken as the key itself."""
def with_field(thing: any, field: str, value: any) -> any {
    copied = {**thing};
    copied[field] = value;
    return copied;
}

async def load_catalog -> CatalogData | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("get_policy_catalog", {}, contract("get_policy_catalog"));
}

async def load_mine -> DocData | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("get_my_policy", {}, contract("get_my_policy"));
}

async def save_version(policy: any, base_version: int, note: str) -> SaveReply | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("save_policy_version", {"policy": policy, "base_version": base_version, "note": note}, contract("save_policy_version"));
}

async def restore_version(version: int, base_version: int) -> SaveReply | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("restore_policy_version", {"version": version, "base_version": base_version}, contract("restore_policy_version"));
}

"""A knob's value as a reader says it; the same words as the server's knob_text."""
def knob_words(knob: KnobData, value: float) -> str {
    if knob.unit == "switch" { return "On" if value else "Off"; }
    if knob.unit == "score" { return signed(value, 2); }
    if knob.unit == "share" {
        whole = abs(value * 100 - round(value * 100)) < 0.001;
        return num(value * 100, 0 if whole else 1) + "%";
    }
    if knob.unit == "multiple" { return num(value, 1) + "× ATR"; }
    if knob.unit == "sessions" { return str(round(value)) + (" session" if round(value) == 1 else " sessions"); }
    return str(round(value));
}

"""One bounded number: its name, its value, a slider across its limits, and what it means. A
switch is a button."""
def KnobRow(knob: KnobData, value: float, editable: bool, change: Callable[[str, float], None]) -> JsxElement {
    <div className="py-3 first:pt-0 last:pb-0" data-knob={knob.name}>
        <div className="flex items-baseline justify-between gap-3">
            <label htmlFor={"knob-" + knob.name} className="text-[13px] font-medium">{knob.label}</label>
            <span className="num shrink-0 text-[13px] text-accent">{knob_words(knob, value)}</span>
        </div>
        {if knob.unit == "switch" {
            <button
                id={"knob-" + knob.name}
                type="button"
                role="switch"
                aria-checked={bool(value)}
                disabled={not editable}
                onClick={lambda { change(knob.name, False if value else True); }}
                className={TAP_QUIET + " mt-1.5"}
            >
                {"Turn off" if value else "Turn on"}
            </button>
        } else {
            <div>
                <input
                    id={"knob-" + knob.name}
                    type="range"
                    min={str(knob.low)}
                    max={str(knob.high)}
                    step={str(knob.step)}
                    value={value}
                    disabled={not editable}
                    aria-valuetext={knob_words(knob, value)}
                    onChange={lambda (e: ChangeEvent) { change(knob.name, float(e.target.value)); }}
                    className="policy-slider mt-1 w-full"
                />
                <div className="num flex justify-between text-[11px] text-faint">
                    <span>{knob_words(knob, knob.low)}</span>
                    <span>{knob_words(knob, knob.high)}</span>
                </div>
            </div>
        }}
        <p className="mt-1 text-[12px] leading-[18px] text-muted">{knob.help}</p>
    </div>
}

"""An empty condition on `metric`, with the first comparison it allows."""
def fresh_condition(metric: MetricData) -> any {
    if metric.kind == "category" {
        return {"metric": metric.name, "op": "in", "number": None, "words": []};
    }
    return {"metric": metric.name, "op": "lt", "number": None, "words": []};
}

"""A number as the reader types it: a share is a percent on screen and a fraction on the wire."""
def shown_number(metric: MetricData | None, number: float | None) -> str {
    if number is None { return ""; }
    if metric is not None and metric.kind == "share" { return str(round(number * 100, 4)); }
    return str(number);
}

def wire_number(metric: MetricData | None, text: str) -> float | None {
    if not text.strip() { return None; }
    found = float(text);
    if isNaN(found) { return None; }
    return found / 100 if metric is not None and metric.kind == "share" else found;
}

"""One test in a rule being built: the metric, the comparison, and its value."""
def ConditionRow(cond: any, catalog: CatalogData, removable: bool, change: Callable[[any], None], remove: Callable[[], None]) -> JsxElement {
    metric: MetricData | None = None;
    for m in catalog.metrics {
        if m.name == cond.metric { metric = m; }
    }
    words: bool = metric is not None and metric.kind == "category";
    ops: list[OpData] = [o for o in catalog.ops if o.words == words];
    groups: list[str] = [];
    for m in catalog.metrics {
        if m.group not in groups { groups.append(m.group); }
    }

    def pick_metric(e: ChangeEvent) {
        for m in catalog.metrics {
            if m.name == e.target.value { change(fresh_condition(m)); }
        }
    }

    <div className="flex flex-col gap-2 rounded-md border border-line p-2.5">
        <select aria-label="Metric" value={cond.metric} onChange={pick_metric} className={TAP_INPUT}>
            {for g in groups {
                <optgroup key={g} label={g}>
                    {for m in catalog.metrics {
                        if m.group == g { <option key={m.name} value={m.name}>{m.label}</option> }
                    }}
                </optgroup>
            }}
        </select>
        {if metric is not None { <p className="text-[12px] text-muted">{metric.help + (" Held stocks only." if metric.held_only else "")}</p> }}
        <div className="flex gap-2">
            <select aria-label="Comparison" value={cond.op} onChange={lambda (e: ChangeEvent) { change({**cond, "op": e.target.value}); }} className={TAP_INPUT + " !w-auto shrink-0"}>
                {for o in ops { <option key={o.value} value={o.value}>{o.label}</option> }}
            </select>
            {if words {
                <input
                    aria-label="Values, separated by commas"
                    placeholder={(metric.choices[0] + ", " + metric.choices[1]) if metric is not None and len(metric.choices) > 1 else "AAPL, MSFT"}
                    defaultValue={", ".join(cond.words)}
                    onChange={lambda (e: ChangeEvent) { change({**cond, "words": [w.strip() for w in e.target.value.split(",") if w.strip()]}); }}
                    className={TAP_INPUT}
                />
            } else {
                <div className="relative min-w-0 flex-1">
                    <input
                        aria-label="Value"
                        type="number"
                        inputMode="decimal"
                        step="any"
                        defaultValue={shown_number(metric, cond.number)}
                        onChange={lambda (e: ChangeEvent) { change({**cond, "number": wire_number(metric, e.target.value)}); }}
                        className={TAP_INPUT + (" pr-7" if metric is not None and metric.kind == "share" else "")}
                    />
                    {if metric is not None and metric.kind == "share" {
                        <span className="absolute right-2.5 top-1/2 -translate-y-1/2 text-[13px] text-faint" aria-hidden="true">%</span>
                    }}
                </div>
            }}
        </div>
        {if words and metric is not None and len(metric.choices) > 0 {
            <p className="text-[12px] text-faint">{"One or more of: " + ", ".join(metric.choices)}</p>
        }}
        {if removable {
            <button type="button" onClick={lambda { remove(); }} className="press min-h-9 self-start text-[12px] text-muted hover:text-down">Remove this test</button>
        }}
    </div>
}

"""Build a new rule. `add` gets the rule; the server checks its limits with the rest of the draft."""
def RuleBuilder(catalog: CatalogData, next_id: str, add: Callable[[any], None], cancel: Callable[[], None]) -> JsxElement {
    has effect: str = "avoid_buy",
        label: str = "",
        conditions: list[any] = [],
        key_seed: int = 0;

    def first_metric -> MetricData {
        for m in catalog.metrics {
            if m.name == "rsi_14" { return m; }
        }
        return catalog.metrics[0];
    }

    shown: list[any] = conditions if len(conditions) > 0 else [fresh_condition(first_metric())];

    def set_condition(index: int, c: any) {
        next_list = list(shown);
        next_list[index] = c;
        conditions = next_list;
        if c.metric != shown[index].metric { key_seed = key_seed + 1; }
    }

    def drop_condition(index: int) {
        conditions = [c for (i, c) in enumerate(shown) if i != index];
        key_seed = key_seed + 1;
    }

    ready: bool = all((c.number is not None or len(c.words) > 0) for c in shown);

    def done {
        add({"id": next_id, "effect": effect, "conditions": shown, "label": label.strip(), "enabled": True});
    }

    <div className="flex flex-col gap-3 rounded-md border border-line-strong bg-panel-2/50 p-3" data-testid="rule-builder">
        <label className="flex flex-col gap-1 text-[12px] text-muted">
            What should it do?
            <select value={effect} onChange={lambda (e: ChangeEvent) { effect = e.target.value; }} className={TAP_INPUT}>
                {for ef in catalog.effects { <option key={ef.value} value={ef.value}>{ef.lead + "…"}</option> }}
            </select>
        </label>
        <div className="flex flex-col gap-2">
            {for (i, c) in enumerate(shown) {
                <ConditionRow
                    key={str(i) + "-" + str(key_seed)}
                    cond={c}
                    catalog={catalog}
                    removable={len(shown) > 1}
                    change={lambda (next_c: any) { set_condition(i, next_c); }}
                    remove={lambda { drop_condition(i); }}
                />
            }}
            {if len(shown) < catalog.max_conditions {
                <button type="button" onClick={lambda { conditions = shown + [fresh_condition(first_metric())]; }} className="press min-h-9 self-start text-[12px] text-accent hover:underline">And also when…</button>
            }}
        </div>
        <label className="flex flex-col gap-1 text-[12px] text-muted">
            Name (optional)
            <input maxLength={80} value={label} onChange={lambda (e: ChangeEvent) { label = e.target.value; }} className={TAP_INPUT}/>
        </label>
        <div className="flex gap-2">
            <button type="button" disabled={not ready} onClick={done} className={TAP_BUTTON + " flex-1"}>Add rule</button>
            <button type="button" onClick={lambda { cancel(); }} className={TAP_QUIET + " flex-1"}>Cancel</button>
        </div>
    </div>
}

def RuleCard(rule: RuleData, sentence: str, editable: bool, toggle: Callable[[], None], remove: Callable[[], None]) -> JsxElement {
    <li className={"flex items-start justify-between gap-2 rounded-md border border-line p-3 " + ("" if rule.enabled else "opacity-60")} data-testid="rule">
        <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-1.5">
                <span className={PILL_BASE + " num " + TONE_QUIET}>{rule.id}</span>
                {if rule.label { <span className="text-[12px] font-medium">{rule.label}</span> }}
                {if not rule.enabled { <span className={PILL_BASE + " " + TONE_WARN}>Paused</span> }}
            </div>
            <p className="mt-1 text-[13px] leading-5">{sentence}</p>
        </div>
        {if editable {
            <div className="flex shrink-0">
                <button type="button" onClick={lambda { toggle(); }} className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover hover:text-text md:size-9" aria-label={("Resume " if not rule.enabled else "Pause ") + rule.id}>
                    {<Play size={15} strokeWidth={1.75}/> if not rule.enabled else <Pause size={15} strokeWidth={1.75}/>}
                </button>
                <button type="button" onClick={lambda { remove(); }} className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover hover:text-down md:size-9" aria-label={"Delete " + rule.id}>
                    <Trash2 size={15} strokeWidth={1.75}/>
                </button>
            </div>
        }}
    </li>
}

"""One stock in a replay: what the run did and what this policy would, and why they differ."""
def ReplayCard(row: RowData, day: str) -> JsxElement {
    <li className="border-b border-line/60 py-2.5 last:border-b-0" data-testid="replay-row">
        <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
            <Link to={"/app/runs/" + day + "/" + row.ticker} className="display min-h-6 text-[17px] leading-6 hover:text-accent">{row.ticker}</Link>
            <div className="flex items-center gap-1.5">
                {if row.changed {
                    <span className="flex items-center gap-1.5">
                        <span className="opacity-70"><ActionBadge action={row.run_action}/></span>
                        <ChevronRight size={12} className="text-faint" aria-label="would become"/>
                    </span>
                }}
                <ActionBadge action={row.action}/>
            </div>
        </div>
        <div className="num mt-0.5 text-[12px] text-muted">
            {(row.sector + " · " if row.sector else "") + ("Held · " if row.held else "") + ("score " + signed(row.score, 2) + " · agreement " + num(row.agreement, 2) if row.score is not None and row.agreement is not None else "No panel score")}
        </div>
        {for note in row.notes { <p key={note} className="mt-1 text-[12px] leading-[18px]">{note}</p> }}
        {if row.unreviewed { <p className="mt-1 text-[12px] leading-[18px] text-warn">The Arbiter never reviewed this buy, because the policy that run used did not propose it.</p> }}
        {for note in row.skipped { <p key={note} className="mt-1 text-[12px] leading-[18px] text-faint">{note}</p> }}
    </li>
}

"""The latest run under the draft. `days` moves between runs."""
def ReplayPanel(view: any, loading: bool, scope_words: str, move: Callable[[str], None]) -> JsxElement {
    has only_changes: bool = True;

    rows: list[RowData] = view.rows if view is not None else [];
    differs: int = view.differs if view is not None else 0;
    shown: list[RowData] = [r for r in rows if r.changed] if only_changes and differs > 0 else rows;

    aside = <div className="flex items-center justify-end gap-1">
        <button type="button" disabled={view is None or not view.previous_day} onClick={lambda { move(view.previous_day); }} className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover disabled:opacity-30 md:size-8" aria-label="Earlier run"><ChevronLeft size={15}/></button>
        <span className="num text-[12px] text-muted">{day_short(view.run_date) if view is not None and view.run_date else "No run"}</span>
        <button type="button" disabled={view is None or not view.next_day} onClick={lambda { move(view.next_day); }} className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover disabled:opacity-30 md:size-8" aria-label="Later run"><ChevronRight size={15}/></button>
    </div>;

    <Panel title="What it would have done" aside={aside} anchor="replay">
        {if view is None {
            <p className="text-[13px] text-muted">Loading the latest run…</p>
        } elif len(view.problems) > 0 {
            <div className="flex flex-col gap-1 text-[13px] text-warn" role="alert">
                {for p in view.problems { <p key={p}>{p}</p> }}
            </div>
        } elif len(rows) == 0 {
            <p className="text-[13px] text-muted">No morning run has decided anything yet. Once one has, every change shows here at once.</p>
        } else {
            <div className={"transition-opacity duration-150 " + ("opacity-60" if loading else "")}>
                <p className="text-[13px]" role="status">
                    {("Nothing differs from what the run decided" if differs == 0 else (str(differs) + (" decision differs" if differs == 1 else " decisions differ") + " from what the run decided")) + " on " + day_long(view.run_date) + "."}
                </p>
                <p className="mt-0.5 text-[12px] text-faint">{scope_words}</p>
                {if differs > 0 {
                    <button type="button" onClick={lambda { only_changes = not only_changes; }} className="press mt-1 min-h-9 text-[12px] text-accent hover:underline">
                        {("Show all " + str(len(rows)) + " stocks") if only_changes else "Show only the differences"}
                    </button>
                }}
                <ul className="mt-1">
                    {for row in shown { <ReplayCard key={row.ticker} row={row} day={view.run_date}/> }}
                </ul>
            </div>
        }}
    </Panel>
}

def HistoryPanel(doc: DocData, editable: bool, busy: bool, restore: Callable[[int], None]) -> JsxElement {
    has opened: bool = False;
    versions: list[VersionData] = doc.history if opened else doc.history[:3];
    <Panel title="History" aside={("Version " + str(doc.version)) if doc.version > 0 else "Defaults"}>
        {if len(doc.history) == 0 {
            <p className="text-[13px] text-muted">Nothing saved yet, so these are the defaults. Every save is kept here and can be restored.</p>
        } else {
            <ol className="flex flex-col">
                {for v in versions {
                    <li key={v.version} className="border-b border-line/60 py-2.5 first:pt-0 last:border-b-0 last:pb-0">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                            <span className="num text-[13px] font-medium">{"Version " + str(v.version)}</span>
                            <span className="num text-[11px] text-faint">{stamp_et(v.saved_at)}</span>
                        </div>
                        <p className="text-[12px] text-muted">{SOURCES.get(v.source, v.source) + (" · " + v.author if v.author else "")}</p>
                        {if v.note { <p className="mt-0.5 text-[12px] italic text-muted">{v.note}</p> }}
                        <ul className="mt-1 flex flex-col gap-0.5 text-[12px]">
                            {for change in v.changes { <li key={change}>{change}</li> }}
                        </ul>
                        {if editable and v.version != doc.version {
                            <button type="button" disabled={busy} onClick={lambda { restore(v.version); }} className="press mt-1 inline-flex min-h-9 items-center gap-1 text-[12px] text-accent hover:underline disabled:opacity-50"><RotateCcw size={12} aria-hidden="true"/>Restore this version</button>
                        }}
                    </li>
                }}
            </ol>
            if len(doc.history) > 3 {
                <button type="button" onClick={lambda { opened = not opened; }} className="press mt-1 min-h-9 text-[12px] text-accent hover:underline">{"Show fewer" if opened else "Show all " + str(len(doc.history))}</button>
            }
            if editable {
                <button type="button" disabled={busy} onClick={lambda { restore(0); }} className="press mt-1 flex min-h-9 items-center gap-1 text-[12px] text-muted hover:text-text disabled:opacity-50"><RotateCcw size={12} aria-hidden="true"/>Restore the defaults</button>
            }
        }}
    </Panel>
}

"""The rule id after the highest in `rules`, as the server numbers them."""
def next_rule_id(rules: list[RuleData]) -> str {
    highest = 0;
    for r in rules {
        n = int(r.id[1:]);
        if not isNaN(n) and n > highest { highest = n; }
    }
    return "R" + str(highest + 1);
}

def:pub PolicyPage -> JsxElement {
    has catalog: CatalogData | None = None,
        doc: DocData | None = None,
        draft: any = None,
        dirty: bool = False,
        note: str = "",
        replay_view: any = None,
        replay_loading: bool = False,
        run_day: str = "",
        building: bool = False,
        busy: bool = False,
        message: str = "",
        problems: list[str] = [],
        error: str = "",
        chat_open: bool = False;

    async def load_all {
        try {
            catalog = await load_catalog();
            doc = await load_mine();
        } except Exception as e {
            error = str(e);
        }
    }

    can with entry {
        load_all();
    }

    # The editor starts from the policy in force, whenever that policy changes.
    doc_key: str = str(doc.version) if doc is not None else "";
    useEffect(lambda {
        if doc is not None {
            draft = doc.policy;
            dirty = False;
            building = False;
            problems = [];
        }
    }, [doc_key]);

    # Replay the draft as it changes, a moment after the last change.
    useEffect(lambda {
        if draft is None { return; }
        live = True;
        async def run_preview {
            fresh: any = None;
            replay_loading = True;
            try {
                fresh = await preview_draft(draft, run_day);
                if live { replay_view = fresh; }
            } except Exception {
                if live { replay_view = {"rows": [], "differs": 0, "problems": ["Could not try this policy just now. Check your connection."], "sentences": [], "rule_sentences": []}; }
            } finally {
                if live { replay_loading = False; }
            }
        }
        timer = setTimeout(run_preview, PREVIEW_DELAY_MS);
        return lambda { live = False; clearTimeout(timer); };
    }, [draft, run_day]);

    def edit(next_draft: any) {
        draft = next_draft;
        dirty = True;
        message = "";
        problems = [];
    }

    def apply_reply(reply: SaveReply | None) {
        if reply is None { return; }
        message = reply.message;
        problems = reply.problems;
        if reply.doc is not None { doc = reply.doc; }
    }

    async def save(e: FormEvent) {
        e.preventDefault();
        if draft is None or doc is None { return; }
        busy = True;
        reply: SaveReply | None = None;
        try {
            reply = await save_version(draft, doc.version, note);
            apply_reply(reply);
            if reply is not None and reply.saved { note = ""; }
        } except Exception {
            message = "Could not save. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    async def restore(version: int) {
        if doc is None { return; }
        busy = True;
        reply: SaveReply | None = None;
        try {
            reply = await restore_version(version, doc.version);
            apply_reply(reply);
        } except Exception {
            message = "Could not restore that version. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    def discard_edits {
        if doc is not None { draft = doc.policy; }
        dirty = False;
        message = "";
        problems = [];
    }

    def proposal_saved(saved_doc: DocData) {
        doc = saved_doc;
        message = "Applied as version " + str(saved_doc.version) + ".";
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if catalog is None or doc is None or draft is None {
        return <Loading label="Loading the policy"/>;
    }

    rule_words: list[str] = replay_view.rule_sentences if replay_view is not None and len(replay_view.rule_sentences) == len(draft.rules) else [r.effect for r in draft.rules];
    if not dirty { rule_words = doc.rule_sentences; }
    sentences: list[str] = replay_view.sentences if dirty and replay_view is not None and len(replay_view.sentences) > 0 else doc.sentences;

    <div className={"flex flex-col gap-5 " + ("pb-20 md:pb-16" if dirty else "")}>
        <div className="min-w-0">
            <h1 className="display text-[30px] leading-9">Your policy</h1>
            <p className="mt-1 max-w-2xl text-[13px] text-muted">When to buy, sell, trim, and hold. Your agent uses this from its next morning run.</p>
        </div>

        <div className="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_360px]">
            <div className="flex min-w-0 flex-col gap-5">
                <Panel title="In plain English" aside={("Version " + str(doc.version)) if doc.version > 0 else "Defaults"}>
                    <ul className="flex flex-col gap-1.5 text-[13px] leading-5">
                        {for s in sentences { <li key={s} className="flex gap-2"><span className="mt-[8px] size-1 shrink-0 rounded-full bg-accent" aria-hidden="true"></span><span>{s}</span></li> }}
                    </ul>
                </Panel>

                <ReplayPanel view={replay_view} loading={replay_loading} scope_words={"Replayed from what that run stored: no orders, no model requests."} move={lambda (d: str) { run_day = d; }}/>

                <Panel title="Rules" aside={str(len(draft.rules)) + " of " + str(catalog.max_rules)} anchor="rules">
                    <div className="flex flex-col gap-2">
                        {if len(draft.rules) == 0 and not building {
                            <p className="text-[13px] text-muted">{"No rules yet, so the numbers below decide everything. A rule tests up to " + str(catalog.max_conditions) + " figures and can block a buy, force a sale, or keep a holding."}</p>
                        }}
                        <ul className="flex flex-col gap-2">
                            {for (i, rule) in enumerate(draft.rules) {
                                <RuleCard
                                    key={rule.id}
                                    rule={rule}
                                    sentence={rule_words[i]}
                                    editable={True}
                                    toggle={lambda { edit({**draft, "rules": [({**r, "enabled": not r.enabled} if r.id == rule.id else r) for r in draft.rules]}); }}
                                    remove={lambda { edit({**draft, "rules": [r for r in draft.rules if r.id != rule.id]}); }}
                                />
                            }}
                        </ul>
                        {if building {
                            <RuleBuilder catalog={catalog} next_id={next_rule_id(draft.rules)} add={lambda (r: any) { edit({**draft, "rules": draft.rules + [r]}); building = False; }} cancel={lambda { building = False; }}/>
                        } elif len(draft.rules) < catalog.max_rules {
                            <button type="button" onClick={lambda { building = True; }} className={TAP_QUIET + " self-start"}><Plus size={14} strokeWidth={2} aria-hidden="true"/>Add a rule</button>
                        }}
                    </div>
                </Panel>

                <div className="grid gap-5 md:grid-cols-2">
                    {for group in catalog.groups {
                        <Panel key={group} title={group}>
                            <div className="flex flex-col divide-y divide-line/60">
                                {for knob in catalog.knobs {
                                    if knob.group == group {
                                        <KnobRow key={knob.name} knob={knob} value={draft[knob.name]} editable={True} change={lambda (name: str, value: float) { edit(with_field(draft, name, value)); }}/>
                                    }
                                }}
                            </div>
                        </Panel>
                    }}
                </div>

                <HistoryPanel doc={doc} editable={True} busy={busy} restore={restore}/>
            </div>

            <PolicyChat
                blocked={dirty}
                open_sheet={chat_open}
                close={lambda { chat_open = False; }}
                saved={proposal_saved}
            />
        </div>

        {if not chat_open {
            <button type="button" onClick={lambda { chat_open = True; }} className={TAP_BUTTON + " fixed right-4 z-30 rounded-full shadow-[var(--shadow-overlay)] lg:hidden " + ("bottom-[calc(12rem+env(safe-area-inset-bottom))]" if dirty else "bottom-[calc(4.75rem+env(safe-area-inset-bottom))]")}>
                <MessageCircle size={16} strokeWidth={1.75} aria-hidden="true"/>Ask
            </button>
        }}

        {if message and not dirty {
            <p className="fixed inset-x-4 bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-20 mx-auto max-w-md rounded-md border border-line-strong bg-overlay px-3 py-2 text-center text-[13px] shadow-[var(--shadow-overlay)] lg:bottom-4" role="status">{message}</p>
        }}

        {if dirty {
            <form onSubmit={save} className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom))] z-20 border-t border-line-strong bg-overlay lg:bottom-0" data-testid="save-bar">
                <div className="mx-auto flex max-w-[1200px] flex-col gap-2 px-4 py-2.5 sm:px-6 md:flex-row md:items-center lg:px-8">
                    <div className="min-w-0 flex-1">
                        {if len(problems) > 0 or message {
                            <p className="text-[12px] text-down" role="alert">{problems[0] if len(problems) > 0 else message}</p>
                        }}
                        <input aria-label="Why you made this change (optional)" placeholder="Why this change? (optional)" maxLength={300} value={note} onChange={lambda (e: ChangeEvent) { note = e.target.value; }} className={TAP_INPUT}/>
                    </div>
                    <div className="flex shrink-0 gap-2">
                        <button type="button" disabled={busy} onClick={discard_edits} className={TAP_QUIET + " flex-1"}>Discard</button>
                        <button type="submit" disabled={busy or (replay_view is not None and len(replay_view.problems) > 0)} className={TAP_BUTTON + " flex-1"}>{"Saving…" if busy else "Save"}</button>
                    </div>
                </div>
            </form>
        }}
    </div>
}

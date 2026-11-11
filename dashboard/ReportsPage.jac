"""Signed-in, insight-only reports: submit, poll, and read the stored card."""
import from "@jac/runtime" { __jacCallFunction, jacIsLoggedIn }
import from "react" { useEffect }
import from "lucide-react" { ChevronDown, ExternalLink }
import from models.reports { ReportsView as ReportsData, ReportView as ReportData, ReportReply as Reply }
import from dashboard.ui.format { count, day_long, pct, signed, title }
import from dashboard.ui.parts { ActionBadge, Empty, ErrorBox, Loading, Overline, Panel, StatusBadge }

# The pinned Jac build cannot seal implicit client bridges for private endpoints.
# Call the same authenticated endpoint through the runtime RPC helper instead.
#
# None once logged out. A private call sent without a token gets a 401, and the runtime answers
# any 401 by dropping the stored token and reloading the page, which would cancel a log-in
# already under way. A poll or a request that finishes just after logging out must not send one.
# The runtime reads the token synchronously when the call starts, so checking first is enough.
async def list_reports -> ReportsData | None {
    if not jacIsLoggedIn() { return None; }
    return await __jacCallFunction("list_reports", {}, {"contract": "[\"trading-agent\",\"reports/api.jac\",\"func\",\"list_reports\"]"});
}

async def request_report(ticker: str) -> Reply {
    return await __jacCallFunction("request_report", {"ticker": ticker}, {"contract": "[\"trading-agent\",\"reports/api.jac\",\"func\",\"request_report\"]"});
}

glob INPUT: str = "h-10 max-md:h-11 w-full rounded-md border border-line-strong bg-panel px-3 text-[13px] max-md:text-[16px] text-text outline-none focus:border-accent focus:ring-2 focus:ring-accent/20";
glob BUTTON: str = "press h-10 max-md:h-11 rounded-md bg-accent px-4 text-[13px] font-medium text-bg hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50";

def ReportCard(item: ReportData) -> JsxElement {
    has show_votes: bool = True, show_sources: bool = True;
    card = item.card;
    <article className="overflow-hidden rounded-md border border-line bg-panel">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-4 py-3 sm:px-5">
            <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <h2 className="display text-[26px] leading-7">{item.ticker}</h2>
                <span className="num text-[12px] text-faint">{day_long(item.trading_date)}</span>
            </div>
            <StatusBadge status={item.status} label={title(item.status)}/>
        </header>
        <div className="space-y-5 p-4 sm:p-5">
            {if item.demo { <p className="rounded-md border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-warn">Demo report — invented prices and research.</p> }}
            {if item.status == "pending" { <p className="text-[13px] text-muted">Queued. This page updates automatically.</p> }}
            {if item.status == "running" { <p className="text-[13px] text-muted">Research and specialist analysis are running.</p> }}
            {if item.error { <ErrorBox message={item.error}/> }}
            {if card is not None {
                <div className="flex flex-wrap items-center gap-3">
                    <ActionBadge action={str(card.action)}/>
                    <div className="flex items-baseline gap-1.5"><span className="num text-[25px] font-medium leading-7">{pct(card.conviction, 0)}</span><span className="text-[12px] text-muted">conviction</span></div>
                    {if card.time_stop { <span className="text-[12px] text-faint sm:ml-auto">{"Through " + day_long(card.time_stop)}</span> }}
                </div>
                <p className="text-[12px] text-muted">Conviction measures panel strength: the absolute weighted vote score times agreement. It is not a chance of profit.</p>
                if item.my_policy is not None {
                    <p className="text-[13px] text-muted" data-testid="report-my-policy">{"Your policy (v" + str(item.my_policy_version) + "): " + (item.my_policy.action if item.my_policy.action != "NO_ACTION" else "no action") + (". " + " ".join(item.my_policy.notes) if len(item.my_policy.notes) > 0 else ".")}</p>
                }
                <div>
                    <Overline>Investment case</Overline>
                    <p className="mt-1.5 max-w-3xl text-[15px] leading-6 text-text">{card.thesis}</p>
                </div>
                if card.note { <p className="rounded-md border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-warn">{card.note}</p> }
                <div className="grid gap-3 md:grid-cols-2">
                    <section className="rounded-md border border-line bg-panel-2/50 p-3.5">
                        <h3 className="text-[13px] font-medium">Key risks</h3>
                        <ul className="mt-2 space-y-1.5 pl-4 text-[13px] leading-5 text-muted list-disc">{for risk in card.risks { <li key={risk}>{risk}</li> }}</ul>
                    </section>
                    <section className="rounded-md border border-line bg-panel-2/50 p-3.5">
                        <h3 className="text-[13px] font-medium">Exit plan</h3>
                        <p className="mt-2 text-[13px] leading-5 text-muted">{card.exit_condition or "No exit condition recorded."}</p>
                        <p className="mt-2 text-[11px] text-faint">{"Time horizon ends " + (day_long(card.time_stop) if card.time_stop else "when the case changes")}</p>
                    </section>
                </div>
                <section className="overflow-hidden rounded-md border border-line">
                    <button type="button" onClick={lambda { show_votes = not show_votes; }} aria-expanded={show_votes} className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left hover:bg-hover">
                        <h3 className="text-[14px] font-medium">Specialist votes</h3>
                        <span className="flex items-center gap-2 text-[11px] text-faint">{count(len(card.specialists), "role")}<ChevronDown size={14} className={"transition-transform " + ("rotate-180" if show_votes else "")}/></span>
                    </button>
                    {if show_votes {
                        <ul className="border-t border-line">{for specialist in card.specialists {
                            <li key={specialist.specialist} className="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-line/60 px-4 py-2.5 first:border-t-0">
                                <span className="w-28 text-[13px] font-medium">{title(specialist.specialist)}</span>
                                <span className="flex flex-wrap gap-1.5">{for (i, stance) in enumerate(specialist.stances) {
                                    <span key={str(i)} className="rounded-[4px] border border-line-strong bg-panel-2 px-2 py-0.5 text-[11px] text-muted">{title(stance)}</span>
                                }}</span>
                                <span className="num ml-auto text-[12px] text-faint">{"mean " + signed(specialist.score)}</span>
                            </li>
                        }}</ul>
                    }}
                </section>
                <section className="overflow-hidden rounded-md border border-line">
                    <button type="button" onClick={lambda { show_sources = not show_sources; }} aria-expanded={show_sources} className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left hover:bg-hover">
                        <h3 className="text-[14px] font-medium">Sources</h3>
                        <span className="flex items-center gap-2 text-[11px] text-faint">{count(len(card.sources), "source")}<ChevronDown size={14} className={"transition-transform " + ("rotate-180" if show_sources else "")}/></span>
                    </button>
                    {if show_sources {
                        <ul className="border-t border-line">{for source in card.sources {
                            <li key={source.url} className="border-t border-line/60 px-4 py-2.5 first:border-t-0">
                                <a href={source.url} target="_blank" rel="noopener noreferrer" className="group flex items-start gap-2 text-[12px] leading-5 text-accent hover:underline"><ExternalLink size={13} className="mt-0.5 shrink-0"/>{source.label}</a>
                            </li>
                        }}</ul>
                    }}
                </section>
            }}
        </div>
    </article>
}

def:pub ReportsPage -> JsxElement {
    has data: ReportsData | None = None, ticker: str = "", error: str = "", message: str = "", busy: bool = False;

    useEffect(lambda {
        active = True;
        loading = False;
        async def refresh {
            if loading { return; }
            loading = True;
            fresh: ReportsData | None = None;
            try {
                fresh = await list_reports();
                if active and fresh is not None { data = fresh; error = ""; }
            } except Exception {
                if active { error = "Could not load reports. Your session may have expired; log in again."; }
            } finally { loading = False; }
        }
        refresh();
        timer = setInterval(refresh, 5000);
        return lambda { active = False; clearInterval(timer); };
    }, []);

    async def submit(e: FormEvent) {
        e.preventDefault();
        busy = True;
        message = "";
        answer: Reply | None = None;
        fresh: ReportsData | None = None;
        try {
            answer = await request_report(ticker);
            message = answer.message;
            fresh = await list_reports();
            if fresh is not None { data = fresh; }
        } except Exception { error = "Could not submit the request. Please try again."; }
        finally { busy = False; }
    }

    <div className="mx-auto max-w-4xl space-y-6">
        <header>
            <Overline>Private research</Overline><h1 className="display mt-1 text-[34px] leading-tight">Stock reports</h1><p className="mt-2 max-w-xl text-[13px] text-muted">Request research, specialist votes, and a cited insight. Requests never place trades.</p>
        </header>
        {if error { <ErrorBox message={error}/> }}
        {if data is None { <Loading label="Loading reports"/> } else {
            <Panel title="Request a report" aside={str(data.remaining) + " new requests available today"}>
                <div className="space-y-3">
                    {if data.message { <p className="text-[12px] text-warn">{data.message}</p> }}
                    <form onSubmit={submit} className="flex flex-col gap-3 sm:flex-row sm:items-end">
                        <div className="w-full max-w-xs space-y-1.5">
                            <label htmlFor="report-ticker" className="text-[12px] font-medium text-muted">S&P 500 stock</label>
                            <input id="report-ticker" list="report-symbols" required={True} value={ticker} onChange={lambda (e: ChangeEvent) { ticker = e.target.value.upper(); }} placeholder="AAPL" className={INPUT}/>
                            <datalist id="report-symbols">{for symbol in data.symbols { <option key={symbol} value={symbol}/> }}</datalist>
                        </div>
                        <button type="submit" disabled={busy or len(data.symbols) == 0} className={BUTTON}>{"Requesting…" if busy else "Request report"}</button>
                    </form>
                    <p className="text-[11px] text-faint">Shared cached reports do not use your quota.</p>
                    {if message { <p role="status" className="text-[12px] text-accent">{message}</p> }}
                </div>
            </Panel>
            <section className="space-y-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2"><h2 className="display text-[26px]">Your reports</h2><span className="text-[12px] text-faint">{count(len(data.reports), "report")}</span></div>
                {if len(data.reports) == 0 { <Empty title="No reports yet">Request a stock above to see its analysis here.</Empty> }}
                {for item in data.reports { <ReportCard key={item.id} item={item}/> }}
            </section>
        }}
    </div>
}

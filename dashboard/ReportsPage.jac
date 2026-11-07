"""Signed-in, insight-only reports: submit, poll, and read the stored card."""
import from "@jac/runtime" { __jacCallFunction, jacIsLoggedIn }
import from "react" { useEffect }
import from models.reports { ReportsView as ReportsData, ReportView as ReportData, ReportReply as Reply }
import from dashboard.ui.parts { ErrorBox, Loading }

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

glob INPUT: str = "min-h-11 rounded-md border border-line bg-panel px-3 py-2 text-text max-md:text-[16px] md:min-h-0";
glob BUTTON: str = "min-h-11 rounded-md bg-accent px-4 py-2 text-bg disabled:opacity-50 md:min-h-0";

def ReportCard(item: ReportData) -> JsxElement {
    card = item.card;
    <article className="rounded-lg border border-line bg-panel p-4 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="font-semibold">{item.ticker + " · " + item.trading_date}</h2>
            <span className="text-sm text-muted">{item.status}</span>
        </div>
        {if item.demo { <p className="text-warn">Demo report — invented prices and research.</p> }}
        {if item.status == "pending" { <p className="text-muted">Queued. This page updates automatically.</p> }}
        {if item.status == "running" { <p className="text-muted">Research and specialist analysis are running.</p> }}
        {if item.error { <ErrorBox message={item.error}/> }}
        {if card is not None {
            <p className="font-semibold">{str(card.action) + " · conviction " + str(round(card.conviction * 100)) + "%"}</p>
            if item.my_policy is not None {
                <p className="text-sm text-muted" data-testid="report-my-policy">{"Your policy (v" + str(item.my_policy_version) + "): " + (item.my_policy.action if item.my_policy.action != "NO_ACTION" else "no action") + (". " + " ".join(item.my_policy.notes) if len(item.my_policy.notes) > 0 else ".")}</p>
            }
            <p>{card.thesis}</p>
            <h3 className="font-semibold">Key risks</h3>
            <ul className="list-disc pl-5">{for risk in card.risks { <li key={risk}>{risk}</li> }}</ul>
            <p><strong>Exit condition: </strong>{card.exit_condition}</p>
            <p><strong>Time horizon ends: </strong>{card.time_stop or "Not specified"}</p>
            if card.note { <p className="text-warn">{card.note}</p> }
            <h3 className="font-semibold">Specialist votes</h3>
            <ul>{for specialist in card.specialists {
                <li key={specialist.specialist}>{specialist.specialist + ": " + ", ".join(specialist.stances)}</li>
            }}</ul>
            <h3 className="font-semibold">Sources</h3>
            <ul className="space-y-1">{for source in card.sources {
                <li key={source.url}><a href={source.url} target="_blank" rel="noopener noreferrer" className="text-accent underline">{source.label}</a></li>
            }}</ul>
        }}
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

    <div className="mx-auto max-w-3xl space-y-5">
        <h1 className="display text-[30px] leading-9">Stock reports</h1>
        <p className="text-muted">Request research, specialist votes, and a cited insight. Requests never place trades.</p>
        {if error { <ErrorBox message={error}/> }}
        {if data is None { <Loading label="Loading reports"/> } else {
            <p className="text-sm text-muted">{str(data.remaining) + " new reports remaining for " + data.trading_date + ". Shared cached reports do not use your quota."}</p>
            if data.message { <p className="text-warn">{data.message}</p> }
            <form onSubmit={submit} className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1">
                    <label htmlFor="report-ticker">S&P 500 stock</label>
                    <input id="report-ticker" list="report-symbols" required={True} value={ticker} onChange={lambda (e: ChangeEvent) { ticker = e.target.value.upper(); }} placeholder="AAPL" className={INPUT}/>
                    <datalist id="report-symbols">{for symbol in data.symbols { <option key={symbol} value={symbol}/> }}</datalist>
                </div>
                <button type="submit" disabled={busy or len(data.symbols) == 0} className={BUTTON}>{"Requesting…" if busy else "Request report"}</button>
            </form>
            if message { <p role="status">{message}</p> }
            if len(data.reports) == 0 { <p className="text-muted">Your requested reports will appear here.</p> }
            for item in data.reports { <ReportCard key={item.id} item={item}/> }
        }}
    </div>
}

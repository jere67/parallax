"""Route placeholders and reusable loading, empty, and error states for issue #106."""
def:pub PageState(kind: str, title: str, detail: str) -> JsxElement {
    state_class = "state-icon loading" if kind == "loading" else "state-icon error" if kind == "error" else "state-icon empty";
    icon = "…" if kind == "loading" else "!" if kind == "error" else "⌁";

    <section className={"route-state loading" if kind == "loading" else "route-state error" if kind == "error" else "route-state empty"} aria-live="polite">
        <span className={state_class} aria-hidden="true">{icon}</span>
        <p className="state-label">{kind.replace("_", " ")}</p>
        <h2>{title}</h2>
        <p className="state-detail">{detail}</p>
    </section>
}

def:pub PortfolioPage -> JsxElement {
    <section className="route-page">
        <div className="route-heading">
            <div><p className="route-eyebrow">PORTFOLIO · OVERVIEW</p><h1>Team portfolio</h1><p className="route-subtitle">Equity, positions, and performance against the stored benchmarks.</p></div>
            <span className="route-date">PAPER ACCOUNT</span>
        </div>
        <PageState kind="empty" title="Portfolio view is ready for stored run data" detail="The dashboard shell is connected. The Portfolio page will show saved equity marks, benchmark performance, positions, and recent orders." />
    </section>
}

def:pub TodayPage -> JsxElement {
    <section className="route-page">
        <div className="route-heading">
            <div><p className="route-eyebrow">DAILY RUN · ACTIVITY</p><h1>Today</h1><p className="route-subtitle">Follow the latest run, covered tickers, and decision outcomes.</p></div>
            <span className="route-date">RUN HISTORY</span>
        </div>
        <PageState kind="empty" title="No run selected" detail="The Today page will show run status, the macro brief, each covered ticker, and links to its decision trail." />
    </section>
}

def:pub DecisionPage -> JsxElement {
    <section className="route-page">
        <div className="route-heading">
            <div><p className="route-eyebrow">DECISION TRAIL</p><h1>Decision detail</h1><p className="route-subtitle">Follow a decision from research evidence through risk checks and fills.</p></div>
            <span className="route-date">AUDIT TRAIL</span>
        </div>
        <PageState kind="empty" title="No decision selected" detail="Choose a ticker from a daily run to inspect its research, specialist samples, adjudication, risk checks, and orders." />
    </section>
}

def:pub NotFoundPage -> JsxElement {
    <section className="route-page">
        <div className="route-heading"><div><p className="route-eyebrow">DASHBOARD</p><h1>Page not found</h1></div></div>
        <PageState kind="error" title="This dashboard page does not exist" detail="Use the navigation to return to Portfolio or Today." />
    </section>
}

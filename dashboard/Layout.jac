"""The frame around every page of the app: the top bar with navigation, the portfolio's status,
the theme switch, settings, and logging out; a banner when the graph holds demo history; and the disclaimer (TDD §9)."""
import from "@jac/runtime" { Link, Outlet, jacLogout, useLocation, useNavigate }
import from "lucide-react" { BookOpen, ChartCandlestick, FileText, History, Newspaper, Settings, SlidersHorizontal, Target }
import from dashboard.ui.brand { DISCLAIMER, REPO_URL, ThemeSwitch, Wordmark }
import from dashboard.ui.rpc { get_portfolio }
import from models.views { PortfolioView as Portfolio }
import from dashboard.ui.format { stamp_et, title }
import from dashboard.ui.parts { StatusBadge }
import from dashboard.ui.pwa { InstallHint, OfflineBanner, register_worker }

glob CHARTS_URL: str = "https://www.tradingview.com/lightweight-charts/";

def NavLink(to: str, active: bool, children: any = None) -> JsxElement {
    tone = "text-text after:bg-accent" if active else "text-muted hover:text-text after:bg-transparent";
    <Link
        to={to}
        className={"relative flex h-12 items-center text-[13px] font-medium transition-colors duration-150 after:absolute after:inset-x-0 after:bottom-[-1px] after:h-0.5 " + tone}
    >
        {children}
    </Link>
}

"""One destination in the phone's bottom tab bar, a full thumb's height."""
def TabLink(to: str, label: str, active: bool, children: any = None) -> JsxElement {
    <Link
        to={to}
        aria-current={"page" if active else None}
        className={"press flex min-h-14 flex-1 flex-col items-center justify-center gap-0.5 text-[11px] font-medium " + ("text-accent" if active else "text-muted")}
    >
        {children}
        <span>{label}</span>
    </Link>
}

def:pub Layout -> JsxElement {
    has info: Portfolio | None = None;

    async can with entry {
        try {
            info = await get_portfolio();
        } except Exception { }
    }

    path = useLocation().pathname;
    nav = useNavigate();
    # The screener's table has more columns than the other pages have room for.
    width = "max-w-[1560px]" if path.startsWith("/app/screener") else "max-w-[1200px]";

    def leave {
        jacLogout();
        nav("/", {"replace": True});
    }

    <div className="flex min-h-dvh flex-col pb-[calc(3.5rem+env(safe-area-inset-bottom))] md:pb-0">
        <header className="sticky top-0 z-20 border-b border-line bg-bg/90 pt-[env(safe-area-inset-top)] backdrop-blur-md">
            <div className={"mx-auto flex h-12 items-center gap-6 px-4 sm:px-6 lg:px-8 " + width}>
                <Wordmark to="/app"/>
                <nav className="hidden shrink-0 items-center gap-4 md:flex lg:gap-6">
                    <NavLink to="/app" active={path == "/app"}>Portfolio</NavLink>
                    <NavLink to="/app/results" active={path.startsWith("/app/results")}>Results</NavLink>
                    <NavLink to="/app/screener" active={path.startsWith("/app/screener") or path.startsWith("/app/stocks")}>Screener</NavLink>
                    <NavLink to="/app/news" active={path.startsWith("/app/news")}>News</NavLink>
                    <NavLink to="/app/runs" active={path.startsWith("/app/runs")}>Runs</NavLink>
                    <NavLink to="/app/policy" active={path.startsWith("/app/policy")}>Policy</NavLink>
                    <NavLink to="/app/reports" active={path.startsWith("/app/reports")}>Reports</NavLink>
                    <NavLink to="/app/specialists" active={path.startsWith("/app/specialists")}>Specialists</NavLink>
                </nav>
                <div className="ml-auto flex items-center gap-3">
                    {if info is not None and info.started {
                        <span className="num hidden items-center gap-1.5 whitespace-nowrap text-[11px] text-faint lg:flex">
                            <span className="size-1.5 rounded-full bg-up" aria-hidden="true"></span>
                            {"Marked " + stamp_et(info.as_of)}
                        </span>
                    }}
                    {if info is not None {
                        <span className="hidden items-center gap-1.5 sm:flex">
                            <StatusBadge status="insight" label="Paper"/>
                            <StatusBadge status={info.mode} label={title(info.mode)}/>
                        </span>
                    }}
                    <ThemeSwitch/>
                    <Link to="/app/settings" aria-label="Settings" title="Settings" className={"press grid size-11 place-items-center rounded-md hover:bg-hover hover:text-text md:size-8 " + ("text-accent" if path.startsWith("/app/settings") else "text-muted")}>
                        <Settings size={16} strokeWidth={1.75} aria-hidden="true"/>
                    </Link>
                    <button type="button" onClick={leave} className="press hidden h-8 rounded-md px-2 text-[12px] font-medium text-muted hover:bg-hover hover:text-text md:block">Log out</button>
                </div>
            </div>
        </header>
        {if info is not None and info.demo {
            <div className="border-b border-warn/25 bg-warn/10">
                <p className={"mx-auto px-4 py-2 text-[12px] text-warn sm:px-6 lg:px-8 " + width}>
                    <span className="font-semibold">Demo data.</span>
                    {" "}These sessions were simulated on this machine by the real consensus, risk gate, and baselines, with made-up prices and votes. Nothing here was traded.
                </p>
            </div>
        }}
        <OfflineBanner/>
        <main className={"mx-auto w-full flex-1 px-4 py-6 sm:px-6 lg:px-8 lg:py-8 " + width}>
            <Outlet/>
        </main>
        <footer className="border-t border-line">
            <div className={"mx-auto flex flex-col gap-2 px-4 py-6 text-[12px] text-faint sm:flex-row sm:items-start sm:justify-between sm:gap-8 sm:px-6 lg:px-8 " + width}>
                <div className="max-w-2xl">
                    <p>{DISCLAIMER}</p>
                    <InstallHint/>
                </div>
                <p className="shrink-0">
                    <a href={REPO_URL} className="transition-colors duration-150 hover:text-text">Source</a>
                    {" · "}
                    <a href={CHARTS_URL} className="transition-colors duration-150 hover:text-text">Charts by TradingView</a>
                </p>
            </div>
        </footer>
        <nav aria-label="Main" className="fixed inset-x-0 bottom-0 z-30 flex border-t border-line bg-bg/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden">
            <TabLink to="/app" label="Portfolio" active={path == "/app"}><BookOpen size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/screener" label="Screener" active={path.startsWith("/app/screener") or path.startsWith("/app/stocks")}><ChartCandlestick size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/news" label="News" active={path.startsWith("/app/news")}><Newspaper size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/runs" label="Runs" active={path.startsWith("/app/runs")}><History size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/policy" label="Policy" active={path.startsWith("/app/policy")}><SlidersHorizontal size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/reports" label="Reports" active={path.startsWith("/app/reports")}><FileText size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/results" label="Results" active={path.startsWith("/app/results") or path.startsWith("/app/specialists")}><Target size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
        </nav>
    </div>
}

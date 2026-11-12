"""The frame around every page of the app: the top bar with navigation, the portfolio's status,
the theme switch, settings, and logging out; a banner when the graph holds demo history; and the disclaimer (TDD §9)."""
import from "react" { useEffect }
import from "@jac/runtime" { Link, Outlet, jacLogout, useLocation, useNavigate }
import from "lucide-react" { BookOpen, ChartCandlestick, ChevronDown, Ellipsis, FileText, History, Newspaper, Settings, SlidersHorizontal, Target, UsersRound }
import from dashboard.ui.brand { DISCLAIMER, REPO_URL, ThemeSwitch, Wordmark }
import from dashboard.ui.rpc { get_portfolio }
import from models.views { PortfolioView as Portfolio }
import from dashboard.ui.format { stamp_et, title }
import from dashboard.ui.parts { StatusBadge }
import from dashboard.ui.pwa { InstallHint, OfflineBanner, register_worker }

glob CHARTS_URL: str = "https://www.tradingview.com/lightweight-charts/";

"""The page an address shows, so moving between pages starts each at its top while moving within
one keeps its place: a news story opens over the feed, and a stock's tabs share its header."""
def:pub page_of(path: str) -> str {
    parts = path.split("/");
    if len(parts) > 2 and parts[2] == "news" {
        return "/app/news";
    }
    if len(parts) > 3 and parts[2] == "stocks" {
        return "/app/stocks/" + parts[3];
    }
    return path;
}

def NavLink(to: str, active: bool, children: any = None) -> JsxElement {
    tone = "text-text after:bg-accent" if active else "text-muted hover:text-text after:bg-transparent";
    <Link
        to={to}
        className={"relative flex h-12 items-center text-[13px] font-medium transition-colors duration-150 after:absolute after:inset-x-0 after:bottom-[-1px] after:h-0.5 " + tone}
    >
        {children}
    </Link>
}

"""True on Reports or Specialists, the pages More holds."""
def:pub in_more(path: str) -> bool {
    return path.startswith("/app/reports") or path.startswith("/app/specialists");
}

"""One page in More's list, a full thumb's height on a phone."""
def MoreLink(to: str, label: str, active: bool, children: any = None) -> JsxElement {
    <Link
        to={to}
        aria-current={"page" if active else None}
        className={"flex min-h-11 items-center gap-2.5 rounded-md px-3 text-[13px] font-medium transition-colors duration-150 hover:bg-hover lg:min-h-9 " + ("text-accent" if active else "text-text")}
    >
        {children}
        {label}
    </Link>
}

"""More: Reports and Specialists, kept out of the main navigation. A disclosure whose items are
links, in the top bar or, on a phone, the bottom tab bar, where it opens upward. It closes on a
pick, a click outside it, or Escape."""
def MoreMenu(path: str, tab: bool = False) -> JsxElement {
    has box: Ref[HTMLDivElement] = Ref(),
        open: bool = False;
    active = in_more(path);

    useEffect(lambda {
        open = False;
    }, [path]);

    useEffect(lambda {
        def away(e: any) {
            el: any = box.current;
            if el is not None and not el.contains(e.target) {
                open = False;
            }
        }
        def on_key(e: KeyboardEvent) {
            if e.key == "Escape" {
                open = False;
            }
        }
        if open {
            document.addEventListener("pointerdown", away);
            window.addEventListener("keydown", on_key);
        }
        return lambda {
            document.removeEventListener("pointerdown", away);
            window.removeEventListener("keydown", on_key);
        };
    }, [open]);

    def flip {
        open = not open;
    }

    <div ref={box} className={"relative flex flex-1" if tab else "relative"}>
        {if tab {
            <button
                type="button"
                aria-expanded={open}
                onClick={flip}
                className={"press flex min-h-14 w-full flex-col items-center justify-center gap-0.5 text-[11px] font-medium " + ("text-accent" if active or open else "text-muted")}
            >
                <Ellipsis size={19} strokeWidth={1.75} aria-hidden="true"/>
                <span>More</span>
            </button>
        }}
        {if not tab {
            <button
                type="button"
                aria-expanded={open}
                onClick={flip}
                className={"relative flex h-12 items-center gap-1 text-[13px] font-medium transition-colors duration-150 after:absolute after:inset-x-0 after:bottom-[-1px] after:h-0.5 " + ("text-text after:bg-accent" if active else "text-muted hover:text-text after:bg-transparent")}
            >
                More
                <ChevronDown size={14} strokeWidth={1.75} aria-hidden="true" className={"transition-transform duration-150 " + ("rotate-180" if open else "")}/>
            </button>
        }}
        {if open {
            <div className={"absolute z-40 w-48 rounded-lg border border-line bg-panel p-1 shadow-overlay " + ("bottom-full right-2 mb-2" if tab else "left-0 top-full mt-1")}>
                <MoreLink to="/app/reports" label="Reports" active={path.startswith("/app/reports")}><FileText size={16} strokeWidth={1.75} aria-hidden="true"/></MoreLink>
                <MoreLink to="/app/specialists" label="Specialists" active={path.startswith("/app/specialists")}><UsersRound size={16} strokeWidth={1.75} aria-hidden="true"/></MoreLink>
            </div>
        }}
    </div>
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

    path: str = useLocation().pathname;
    nav = useNavigate();
    # A link inside the app keeps the old page's scroll, so a new page would open part way down.
    # A one-line effect compiles to an arrow that returns its value, which React would later call
    # as the effect's cleanup, so the scroll is a function that returns nothing.
    page = page_of(path);
    def to_top {
        window.scrollTo(0, 0);
    }
    useEffect(lambda {
        to_top();
    }, [page]);
    # The screener's table has more columns than the other pages have room for.
    width = "max-w-[1560px]" if path.startswith("/app/screener") else "max-w-[1200px]";

    def leave {
        jacLogout();
        nav("/", {"replace": True});
    }

    <div className="flex min-h-dvh flex-col pb-[calc(3.5rem+env(safe-area-inset-bottom))] lg:pb-0">
        <header className="sticky top-0 z-20 border-b border-line bg-bg/90 pt-[env(safe-area-inset-top)] backdrop-blur-md">
            <div className={"mx-auto flex h-12 items-center gap-6 px-4 sm:px-6 lg:px-8 " + width}>
                <Wordmark to="/app"/>
                <nav className="hidden shrink-0 items-center gap-4 lg:flex xl:gap-6">
                    <NavLink to="/app" active={path == "/app"}>Portfolio</NavLink>
                    <NavLink to="/app/results" active={path.startswith("/app/results")}>Results</NavLink>
                    <NavLink to="/app/screener" active={path.startswith("/app/screener") or path.startswith("/app/stocks")}>Screener</NavLink>
                    <NavLink to="/app/news" active={path.startswith("/app/news")}>News</NavLink>
                    <NavLink to="/app/runs" active={path.startswith("/app/runs")}>Runs</NavLink>
                    <NavLink to="/app/policy" active={path.startswith("/app/policy")}>Policy</NavLink>
                    <MoreMenu path={path}/>
                </nav>
                <div className="ml-auto flex items-center gap-3">
                    {if info is not None and info.started {
                        <span className="num hidden items-center gap-1.5 whitespace-nowrap text-[11px] text-faint xl:flex">
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
                    <Link to="/app/settings" aria-label="Settings" title="Settings" className={"press grid size-11 place-items-center rounded-md hover:bg-hover hover:text-text lg:size-8 " + ("text-accent" if path.startswith("/app/settings") else "text-muted")}>
                        <Settings size={16} strokeWidth={1.75} aria-hidden="true"/>
                    </Link>
                    <button type="button" onClick={leave} className="press hidden h-8 rounded-md px-2 text-[12px] font-medium text-muted hover:bg-hover hover:text-text lg:block">Log out</button>
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
        <nav aria-label="Main" className="fixed inset-x-0 bottom-0 z-30 flex border-t border-line bg-bg/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-md lg:hidden">
            <TabLink to="/app" label="Portfolio" active={path == "/app"}><BookOpen size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/screener" label="Screener" active={path.startswith("/app/screener") or path.startswith("/app/stocks")}><ChartCandlestick size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/news" label="News" active={path.startswith("/app/news")}><Newspaper size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/runs" label="Runs" active={path.startswith("/app/runs")}><History size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/policy" label="Policy" active={path.startswith("/app/policy")}><SlidersHorizontal size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <TabLink to="/app/results" label="Results" active={path.startswith("/app/results")}><Target size={19} strokeWidth={1.75} aria-hidden="true"/></TabLink>
            <MoreMenu path={path} tab={True}/>
        </nav>
    </div>
}

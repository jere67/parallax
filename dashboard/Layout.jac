"""The frame around every page: the top bar with navigation, the portfolio's status, and the
theme switch; a banner when the graph holds demo history; and the disclaimer (TDD §9)."""
import from "@jac/runtime" { Link, Outlet, useLocation }
import from "lucide-react" { Moon, Sun }
import from dashboard.api { get_portfolio }
import from models.views { PortfolioView as Portfolio }
import from dashboard.ui.format { stamp_et, title }
import from dashboard.ui.parts { StatusBadge }
import from dashboard.ui.theme { is_dark, set_theme }

# The same words as action/insights.jac DISCLAIMER, which stays server-side with the cards.
glob DISCLAIMER: str = "An educational student project trading simulated money. Nothing here is investment advice, and past simulated performance does not predict future results.";
glob REPO_URL: str = "https://github.com/jere67/eecs449-project";
glob CHARTS_URL: str = "https://www.tradingview.com/lightweight-charts/";

def NavLink(to: str, active: bool, children: any = None) -> JsxElement {
    tone = "text-text after:bg-accent" if active else "text-muted hover:text-text after:bg-transparent";
    <Link
        to={to}
        className={"relative flex h-12 items-center px-1 text-[13px] font-medium transition-colors after:absolute after:inset-x-0 after:bottom-[-1px] after:h-0.5 after:rounded-full " + tone}
    >
        {children}
    </Link>
}

def ThemeSwitch -> JsxElement {
    has dark: bool = is_dark();

    def flip {
        set_theme("light" if dark else "dark");
        dark = not dark;
    }

    <button
        type="button"
        onClick={flip}
        className="grid size-8 place-items-center rounded-md text-muted transition-colors hover:bg-hover hover:text-text"
        aria-label={"Switch to light theme" if dark else "Switch to dark theme"}
        title={"Light theme" if dark else "Dark theme"}
    >
        {<Sun size={16} strokeWidth={1.75}/> if dark else <Moon size={16} strokeWidth={1.75}/>}
    </button>
}

def:pub Layout -> JsxElement {
    has info: Portfolio | None = None;

    async can with entry {
        try {
            info = await get_portfolio();
        } except Exception { }
    }

    path = useLocation().pathname;

    <div className="flex min-h-dvh flex-col">
        <header className="sticky top-0 z-20 border-b border-line bg-panel/90 backdrop-blur">
            <div className="mx-auto flex h-12 max-w-[1440px] items-center gap-6 px-4 sm:px-6">
                <Link to="/" className="flex items-center gap-2 text-[14px] font-semibold tracking-tight">
                    <svg viewBox="0 0 16 16" className="size-4 text-accent" aria-hidden="true">
                        <path d="M1 12 L5.5 7 L9 9.5 L15 3" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                    <span className="hidden sm:inline">Trading Agent</span>
                </Link>
                <nav className="flex items-center gap-5">
                    <NavLink to="/" active={path == "/"}>Portfolio</NavLink>
                    <NavLink to="/runs" active={path.startsWith("/runs")}>Runs</NavLink>
                </nav>
                <div className="ml-auto flex items-center gap-3">
                    {if info is not None and info.started {
                        <span className="num hidden text-[12px] text-faint md:inline">
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
                </div>
            </div>
        </header>
        {if info is not None and info.demo {
            <div className="border-b border-warn/25 bg-warn-soft">
                <p className="mx-auto max-w-[1440px] px-4 py-2 text-[12px] text-warn sm:px-6">
                    <span className="font-semibold">Demo data.</span>
                    {" "}These sessions were simulated on this machine by the real consensus, risk gate, and baselines, with made-up prices and votes. Nothing here was traded.
                </p>
            </div>
        }}
        <main className="mx-auto w-full max-w-[1440px] flex-1 px-4 py-5 sm:px-6 sm:py-6">
            <Outlet/>
        </main>
        <footer className="border-t border-line">
            <div className="mx-auto flex max-w-[1440px] flex-col gap-2 px-4 py-5 text-[12px] text-faint sm:flex-row sm:items-start sm:justify-between sm:gap-8 sm:px-6">
                <p className="max-w-3xl">{DISCLAIMER}</p>
                <p className="shrink-0">
                    <a href={REPO_URL} className="hover:text-text">Source</a>
                    {" · "}
                    <a href={CHARTS_URL} className="hover:text-text">Charts by TradingView</a>
                </p>
            </div>
        </footer>
    </div>
}

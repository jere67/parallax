"""Shared dashboard shell and client-side route table (TDD §10, issue #106)."""
import from "@jac/runtime" { Link, Navigate, Outlet, Route, Router, Routes, useLocation }
import from .routes { DecisionPage, NotFoundPage, PortfolioPage, TodayPage }

def:pub DashboardLayout -> JsxElement {
    has theme: str = "light";

    location = useLocation();
    is_portfolio = location.pathname == "/portfolio" or location.pathname == "/";
    is_today = location.pathname == "/today";

    async def toggle_theme {
        theme = "dark" if theme == "light" else "light";
    }

    <div className={"dashboard-shell theme-dark" if theme == "dark" else "dashboard-shell theme-light"}>
        <aside className="sidebar">
            <Link className="brand" to="/portfolio" aria-label="Trading Agent dashboard home">
                <span className="brand-mark" aria-hidden="true"><i></i><i></i><i></i></span>
                <span className="brand-copy"><strong>Trading Agent</strong><small>PUBLIC PAPER PORTFOLIO</small></span>
            </Link>

            <p className="nav-caption">DASHBOARD</p>
            <nav className="primary-nav" aria-label="Dashboard pages">
                <Link className={"nav-link active" if is_portfolio else "nav-link"} to="/portfolio">
                    <span className="nav-glyph" aria-hidden="true">◫</span><span>Portfolio</span>
                </Link>
                <Link className={"nav-link active" if is_today else "nav-link"} to="/today">
                    <span className="nav-glyph" aria-hidden="true">◷</span><span>Today</span>
                </Link>
            </nav>

            <div className="sidebar-bottom">
                <div className="account-card">
                    <span className="account-dot" aria-hidden="true"></span>
                    <span><strong>Simulation</strong><small>Stored run data · read only</small></span>
                </div>
                <p className="sidebar-note">Research and decisions are displayed from the team's saved records.</p>
            </div>
        </aside>

        <div className="main-column">
            <header className="topbar">
                <div className="breadcrumb"><span>TRADING AGENT</span><span className="crumb-divider">/</span><strong>{"Today" if is_today else "Portfolio" if is_portfolio else "Decision detail"}</strong></div>
                <div className="topbar-actions">
                    <span className="read-only-tag"><span className="status-dot"></span>Paper simulation</span>
                    <button className="theme-toggle" onClick={toggle_theme} aria-label={"Switch to light theme" if theme == "dark" else "Switch to dark theme"} title={"Switch to light theme" if theme == "dark" else "Switch to dark theme"}>
                        <span aria-hidden="true">{"☀" if theme == "dark" else "☾"}</span><span>{"Light" if theme == "dark" else "Dark"}</span>
                    </button>
                </div>
            </header>

            <main className="main-content"><Outlet /></main>

            <footer className="site-footer">
                <span>Educational student project · Simulated money</span>
                <span>This is not investment advice. Simulated past performance does not predict future results.</span>
            </footer>
        </div>
    </div>
}

def:pub HomePage -> JsxElement {
    <>
        <link rel="stylesheet" href="/static/assets/dashboard.css" />
        <Router>
            <Routes>
                <Route path="/" element={<DashboardLayout />}>
                    <Route index element={<Navigate to="/portfolio" replace={True} />} />
                    <Route path="portfolio" element={<PortfolioPage />} />
                    <Route path="today" element={<TodayPage />} />
                    <Route path="decision/:ticker" element={<DecisionPage />} />
                    <Route path="*" element={<NotFoundPage />} />
                </Route>
            </Routes>
        </Router>
    </>
}

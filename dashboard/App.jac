"""The routes (TDD §10): the public front page and the log-in pages, and the app under /app, where
every page needs an account. A manual route table, since file-based routing reads only a pages/
directory at the project root and the dashboard lives in dashboard/."""
import from "@jac/runtime" { Navigate, Outlet, Route, Router, Routes, jacIsLoggedIn, useLocation }
import from dashboard.AuthPage { AuthPage }
import from dashboard.DecisionPage { DecisionPage }
import from dashboard.Landing { Landing }
import from dashboard.Layout { Layout }
import from dashboard.NewsPage { NewsPage }
import from dashboard.NotFound { NotFound }
import from dashboard.PolicyPage { PolicyPage }
import from dashboard.PortfolioPage { PortfolioPage }
import from dashboard.ReportsPage { ReportsPage }
import from dashboard.RunPage { RunPage }
import from dashboard.SettingsPage { SettingsPage }
import from dashboard.ui.pwa { register_worker }
import from dashboard.ui.theme { restore_theme }

"""The app's pages, for a reader with an account. Anyone else goes to log in and comes back."""
def RequireAccount -> JsxElement {
    place = useLocation();
    if not jacIsLoggedIn() {
        return <Navigate to={"/login?next=" + encodeURIComponent(place.pathname + place.search)} replace={True}/>;
    }
    <Outlet/>
}

"""An address from before the app moved under /app, as in a shared link or a printed QR code."""
def Moved -> JsxElement {
    place = useLocation();
    <Navigate to={"/app" + place.pathname + place.search} replace={True}/>
}

def:pub App -> JsxElement {
    restore_theme();
    register_worker();
    <Router>
        <Routes>
            <Route path="/" element={<Landing/>}/>
            <Route path="/login" element={<AuthPage/>}/>
            <Route path="/signup" element={<AuthPage creating={True}/>}/>
            <Route path="/news/*" element={<Moved/>}/>
            <Route path="/runs/*" element={<Moved/>}/>
            <Route path="/policy" element={<Moved/>}/>
            <Route path="/reports" element={<Moved/>}/>
            <Route path="/app" element={<RequireAccount/>}>
                <Route element={<Layout/>}>
                    <Route index={True} element={<PortfolioPage/>}/>
                    <Route path="news/*" element={<NewsPage/>}/>
                    <Route path="policy" element={<PolicyPage/>}/>
                    <Route path="reports" element={<ReportsPage/>}/>
                    <Route path="settings" element={<SettingsPage/>}/>
                    <Route path="runs" element={<RunPage/>}/>
                    <Route path="runs/:day" element={<RunPage/>}/>
                    <Route path="runs/:day/:ticker" element={<DecisionPage/>}/>
                    <Route path="*" element={<NotFound/>}/>
                </Route>
            </Route>
            <Route path="*" element={<NotFound/>}/>
        </Routes>
    </Router>
}

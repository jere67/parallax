"""The dashboard's routes (TDD §10). A manual route table, since file-based routing reads only
a pages/ directory at the project root and the dashboard lives in dashboard/."""
import from "@jac/runtime" { Router, Routes, Route }
import from dashboard.Layout { Layout }
import from dashboard.NotFound { NotFound }
import from dashboard.PortfolioPage { PortfolioPage }
import from dashboard.RunPage { RunPage }
import from dashboard.DecisionPage { DecisionPage }
import from dashboard.ui.theme { restore_theme }

def:pub App -> JsxElement {
    restore_theme();
    <Router>
        <Routes>
            <Route path="/" element={<Layout/>}>
                <Route index={True} element={<PortfolioPage/>}/>
                <Route path="runs" element={<RunPage/>}/>
                <Route path="runs/:day" element={<RunPage/>}/>
                <Route path="runs/:day/:ticker" element={<DecisionPage/>}/>
                <Route path="*" element={<NotFound/>}/>
            </Route>
        </Routes>
    </Router>
}

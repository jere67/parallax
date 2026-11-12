"""Endpoint smoke tests: every declared endpoint is served, and health answers."""
import re;
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent;
glob SKIP_DIRS: set[str] = {".git", ".jac", "dist", "node_modules", "tests"};
glob FUNCTION_DECL: re.Pattern[str] = re.compile(r"def:(?:pub|protect)\s+(\w+)([^{;]*)");
glob WALKER_DECL: re.Pattern[str] = re.compile(r"walker:(?:pub|protect)\s+(\w+)");
# Browser globals place a module client (jac guide jac-codespaces), so its :pub helpers are
# exports for other client modules, not endpoints.
glob BROWSER_GLOBAL: re.Pattern[str] = re.compile(r"\b(?:window|document|localStorage)\.");

"""Names of the functions and walkers marked :pub or :protect in the source, skipping client
components and modules that use browser globals."""
def declared_endpoints -> tuple[set[str], set[str]] {
    functions: set[str] = set();
    walkers: set[str] = set();
    for path in PROJECT_ROOT.rglob("*.jac") {
        if SKIP_DIRS & set(path.relative_to(PROJECT_ROOT).parts) or path.name.startswith("fixture_") {
            continue;
        }
        source = path.read_text();
        if BROWSER_GLOBAL.search(source) {
            continue;
        }
        for found in FUNCTION_DECL.finditer(source) {
            if "JsxElement" not in found.group(2) {
                functions.add(found.group(1));
            }
        }
        for found in WALKER_DECL.finditer(source) {
            walkers.add(found.group(1));
        }
    }
    return (functions, walkers);
}

def start_client -> JacTestClient {
    return JacTestClient.from_file(
        str(PROJECT_ROOT / "main.jac"), base_path=tempfile.mkdtemp()
    );
}

test "endpoint discovery finds the health endpoint" {
    (functions, _) = declared_endpoints();
    assert "health" in functions;
    assert "App" not in functions and "Layout" not in functions;
}

test "every declared endpoint is served" {
    (functions, walkers) = declared_endpoints();
    client = start_client();
    try {
        served_functions = set(client.get("/functions").json()["data"]["functions"]);
        served_walkers = set(client.get("/walkers").json()["data"]["walkers"]);
    } finally {
        client.close();
    }
    missing = sorted(functions - served_functions) + sorted(walkers - served_walkers);
    assert not missing, f"Not served: {missing}. Import each one by name in main.jac (TDD §3, rule 7).";
}

"""Names of the scheduled jobs: they run on the server's clock, so none may be an endpoint."""
def scheduled_jobs -> set[str] {
    found: set[str] = set();
    for path in PROJECT_ROOT.rglob("*.jac") {
        if SKIP_DIRS & set(path.relative_to(PROJECT_ROOT).parts) {
            continue;
        }
        for hit in re.finditer(r"@schedule\([^)]*\)\s*(?:def|walker)(?::\w+)?\s+(\w+)", path.read_text()) {
            found.add(hit.group(1));
        }
    }
    return found;
}

test "no scheduled job is served, so no caller can fire the trading day by hand" {
    jobs = scheduled_jobs();
    assert {"morning_job", "trading_job", "manual_run_job", "agents_trading_job"} <= jobs, jobs;
    client = start_client();
    try {
        served = set(client.get("/functions").json()["data"]["functions"]) | set(client.get("/walkers").json()["data"]["walkers"]);
    } finally {
        client.close();
    }
    assert jobs & served == set(), jobs & served;
    assert "DailyRun" not in served;
}

test "only health answers an anonymous caller; everything else takes an account" {
    client = start_client();
    try {
        served = client.get("/functions").json()["data"]["functions"];
        walkers = client.get("/walkers").json()["data"]["walkers"];
        open_ones = [
            name
            for name in served
            if client.post(f"/function/{name}", json={}).status_code not in [401, 403, 422]
        ];
        open_walkers = [
            name
            for name in walkers
            if client.post(f"/walker/{name}", json={}).status_code not in [401, 403, 422]
        ];
    } finally {
        client.close();
    }
    assert open_ones == ["health"], open_ones;
    assert open_walkers == [], open_walkers;
    # A required argument is checked before the token, so a 422 above proves nothing about a public
    # endpoint. The source says which are public: health, and the pure formatting the pages share,
    # which reads no data. The pages' own wrappers (dashboard/ui) are client code.
    public = {
        found.group(1)
        for path in PROJECT_ROOT.rglob("*.jac")
        if not SKIP_DIRS & set(path.relative_to(PROJECT_ROOT).parts)
            and not path.name.startswith("fixture_")
            and "ui" not in path.relative_to(PROJECT_ROOT).parts
            and not BROWSER_GLOBAL.search(path.read_text())
        for found in re.finditer(r"def:pub\s+(\w+)([^{;]*)", path.read_text())
        if "JsxElement" not in found.group(2)
    };
    assert public - {"health", "money", "percent", "ratio", "chart_points"} == set(), public;
}

test "health answers ok with a UTC timestamp" {
    client = start_client();
    try {
        resp = client.post("/function/health", json={});
    } finally {
        client.close();
    }
    assert resp.status_code == 200;
    result = resp.json()["data"]["result"];
    assert result["status"] == "ok";
    assert result["checked_at"].endswith("+00:00");
}

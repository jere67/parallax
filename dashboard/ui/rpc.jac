"""The client's calls to the server's private endpoints. The pinned Jac build cannot seal implicit
client bridges for private endpoints, so each goes through the runtime's RPC helper by name
(dashboard/ui/retry.jac). A call made while signed out returns nothing: the runtime answers a 401
by reloading the page, which would cancel a log-in already under way."""
import from "@jac/runtime" { jacIsLoggedIn }
import from dashboard.ui.retry { call_function }
import from models.accounts { AgentReply, AgentSettings, KeysReply, TransferStatus }
import from models.market { HistoryView, ScreenerView, StockAboutView, StockView }
import from models.evaluation { Evaluation }
import from models.views { NewsFeed, NewsStory, PerformanceView, PortfolioView, RunSummary, RunView, SpecialistSummaryView, TrailView }

def contract(file: str, name: str) -> dict[str, str] {
    return {"contract": "[\"trading-agent\",\"" + file + "\",\"func\",\"" + name + "\"]"};
}

async def call(file: str, name: str, args: dict[str, any] = {}) -> any {
    if not jacIsLoggedIn() {
        return None;
    }
    return await call_function(name, args, contract(file, name));
}

async def:pub get_portfolio -> PortfolioView | None {
    return await call("dashboard/api.jac", "get_portfolio");
}

async def:pub get_performance -> PerformanceView | None {
    return await call("dashboard/api.jac", "get_performance");
}

async def:pub get_evaluation -> Evaluation | None {
    return await call("dashboard/api.jac", "get_evaluation");
}

async def:pub get_specialists -> list[SpecialistSummaryView] {
    found: any = await call("dashboard/api.jac", "get_specialists");
    return found or [];
}

async def:pub list_runs -> list[RunSummary] {
    found: any = await call("dashboard/api.jac", "list_runs");
    return found or [];
}

async def:pub get_run(run_date: str = "") -> RunView | None {
    return await call("dashboard/api.jac", "get_run", {"run_date": run_date});
}

async def:pub get_news_feed(q: str = "", ticker: str = "", desk: str = "", lean: str = "", day: str = "", held: bool = False, offset: int = 0, limit: int = 50) -> NewsFeed | None {
    return await call("dashboard/news.jac", "get_news_feed", {"q": q, "ticker": ticker, "desk": desk, "lean": lean, "day": day, "held": held, "offset": offset, "limit": limit});
}

async def:pub get_news_story(day: str, ticker: str, desk: str, n: int = 0, requested: bool = False) -> NewsStory | None {
    return await call("dashboard/news.jac", "get_news_story", {"day": day, "ticker": ticker, "desk": desk, "n": n, "requested": requested});
}

async def:pub get_decision_trail(run_date: str, ticker: str) -> TrailView | None {
    return await call("dashboard/api.jac", "get_decision_trail", {"run_date": run_date, "ticker": ticker});
}

async def:pub get_agent_settings -> AgentSettings | None {
    return await call("accounts/api.jac", "get_agent_settings");
}

async def:pub save_agent_keys(alpaca_key: str, alpaca_secret: str, openrouter_key: str, finnhub_key: str) -> KeysReply | None {
    return await call("accounts/api.jac", "save_agent_keys", {"alpaca_key": alpaca_key, "alpaca_secret": alpaca_secret, "openrouter_key": openrouter_key, "finnhub_key": finnhub_key});
}

async def:pub remove_agent_keys(provider: str) -> AgentReply | None {
    return await call("accounts/api.jac", "remove_agent_keys", {"provider": provider});
}

async def:pub set_paper_trading(on: bool) -> AgentReply | None {
    return await call("accounts/api.jac", "set_paper_trading", {"on": on});
}

async def:pub start_my_run -> AgentReply | None {
    return await call("accounts/api.jac", "start_my_run");
}

async def:pub get_transfer_status -> TransferStatus | None {
    return await call("accounts/transfer.jac", "get_transfer_status");
}

async def:pub start_transfer(data: str) -> TransferStatus | None {
    return await call("accounts/transfer.jac", "start_transfer", {"data": data});
}

async def:pub screen_stocks(
    filters: list[dict[str, any]] = [],
    search: str = "",
    symbols: list[str] = [],
    sort: str = "market_cap",
    descending: bool = True,
    columns: list[str] = [],
    offset: int = 0,
    limit: int = 100
) -> ScreenerView | None {
    return await call("market/api.jac", "screen_stocks", {"filters": filters, "search": search, "symbols": symbols, "sort": sort, "descending": descending, "columns": columns, "offset": offset, "limit": limit});
}

async def:pub get_stock(symbol: str) -> StockView | None {
    return await call("market/api.jac", "get_stock", {"symbol": symbol});
}

async def:pub get_stock_history(symbol: str) -> HistoryView | None {
    return await call("market/api.jac", "get_stock_history", {"symbol": symbol});
}

async def:pub get_stock_about(symbol: str) -> StockAboutView | None {
    return await call("market/api.jac", "get_stock_about", {"symbol": symbol});
}

"""The policy endpoints over a seeded team run, for policy_api_tests.jac. `set_admin` stands in
for the admin role, which comes from the server's user store; the Playwright suite signs in as
the real admin."""
import agents.policy_assistant as policy_assistant;
import accounts.store as store;
import from accounts.api { save_agent_keys }
import from models.accounts { KeysReply }
import from jaclang.byllm.lib { MockLLM, MockRawResponse }
import from action.fixtures { Call, finished_run }
import from agents.models { LIMITER }
import from models.graph { Concluded, ConsensusResult, Coverage, Covers, Portfolio, PortfolioMode, TradeAction }
import from policy.api { get_my_policy, get_policy_catalog, preview_policy, restore_policy_version, save_policy_version }
import from policy.chat { ANSWERS, apply_policy_proposal, discard_policy_proposal, get_policy_chat, send_policy_message }
import from research.collector { utc_now }
import from run.public { public }

def:priv set_admin(on: bool) -> str {
    setattr(store, "is_admin_root", lambda (_users: object, _caller: str) -> bool { on; });
    store._ROLES.clear();
    return "ok";
}

def:priv seed_policy_run -> str {
    team = public(root.shared ++> Portfolio(name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-10-21T13:00:00+00:00"));
    run = finished_run(team, "2026-11-03", [Call(ticker="AAPL", action=TradeAction.NO_ACTION, conviction=0.2), Call(ticker="MSFT", action=TradeAction.BUY, conviction=0.4)]);
    scores = {"AAPL": (0.3, 0.45), "MSFT": (0.5, 0.8)};
    for cov in [run ->:Covers:->[?:Coverage]] {
        (score, agreement) = scores[cov.ticker];
        public(cov +>:Concluded():+> ConsensusResult(ticker=cov.ticker, score=score, agreement=agreement, ci_low=score - 0.1, ci_high=score + 0.1, draft_action=TradeAction.BUY if agreement >= 0.5 else TradeAction.NO_ACTION));
    }
    return "ok";
}

"""Answer the next chat messages with these raw model outputs, through byLLM's real parser."""
def:priv script_assistant(outputs: list[str]) -> str {
    setattr(policy_assistant, "policy_llm", MockLLM(model_name="mock-policy", config={"outputs": [MockRawResponse(content=o) for o in outputs]}));
    return "ok";
}

"""Pretend the morning run has already used `requests` of the day's model requests."""
def:priv spend_requests(requests: int) -> str {
    LIMITER.sent_by_day[utc_now().date().isoformat()] = requests;
    return "ok";
}

"""Send a message in a transaction that then fails, as a serialization conflict would."""
def:priv send_then_fail(text: str) -> str {
    send_policy_message(text);
    raise RuntimeError("the transaction failed");
}

"""Collect the finished answers in a transaction that then fails."""
def:priv collect_then_fail -> str {
    get_policy_chat();
    raise RuntimeError("the transaction failed");
}

"""How many model calls the chat has started and not yet forgotten."""
def:priv answers_started -> int {
    return len(ANSWERS);
}

"""Wait for every started model call to finish, without collecting any."""
def:priv calls_finished -> bool {
    return all(f.done() for f in ANSWERS.values());
}

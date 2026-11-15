"""Which asset classes each agent trades (models/assets.jac).

An owner opts their agent into classes on the settings page; the choice lives on their
AgentAccount, which the scheduled jobs read but never write. The team's agent has no account, so
an admin's choice is saved as an AssetChoice on root.shared, newest first. Every agent trades
stocks alone until someone chooses more.

Options are bought on the stock panel's views (action/options.jac), so an agent that trades options
researches stocks even when it places no stock orders.
"""
import from accounts.store { my_account }
import from models.accounts { AgentAccount, AssetChoice, AssetOption }
import from models.assets { ASSET_CLASSES, ASSET_LABELS, CRYPTO, DEFAULT_CLASSES, OPTIONS, STOCKS, clean_classes }
import from models.graph { Portfolio }
import from research.collector { utc_now }
import from run.guard { TEAM_PORTFOLIO }
import from run.public { public }

glob ASSET_NOTES: dict[str, str] = {
    STOCKS: "S&P 500 stocks from the morning screen.",
    CRYPTO: "The most traded coins quoted in dollars. Crypto trades every day, so the agent also runs on weekends.",
    OPTIONS: "Calls on the panel's confident buys, and puts on its confident sells of stocks it does not hold. Each contract costs its premium, at most 1% of equity."
};

"""The team's choice: the newest saved, or stocks alone."""
def team_classes -> list[str] {
    found = sorted([c for c in [root.shared -->[?:AssetChoice]]], key=lambda (c: AssetChoice) { c.saved_at; });
    return clean_classes(found[-1].classes) if found and clean_classes(found[-1].classes) else list(DEFAULT_CLASSES);
}

"""An owner's choice, or stocks alone for an account that never chose."""
def account_classes(account: AgentAccount | None) -> list[str] {
    if account is None {
        return list(DEFAULT_CLASSES);
    }
    return clean_classes(account.asset_classes) or list(DEFAULT_CLASSES);
}

"""The classes `portfolio`'s agent trades. The team portfolio follows the admins' choice; an agent's
follows its owner's, read as the owner (run/agents.jac `as_agent`)."""
def classes_for(portfolio: Portfolio) -> list[str] {
    if portfolio.name == TEAM_PORTFOLIO {
        return team_classes();
    }
    return account_classes(my_account());
}

"""The settings page's rows for `enabled`."""
def asset_options(enabled: list[str]) -> list[AssetOption] {
    return [AssetOption(name=c, label=ASSET_LABELS[c], enabled=c in enabled, note=ASSET_NOTES[c]) for c in ASSET_CLASSES];
}

"""Save the team's choice. Returns the classes saved."""
def save_team_classes(classes: list[str]) -> list[str] {
    chosen = clean_classes(classes);
    public(root.shared ++> AssetChoice(classes=chosen, saved_at=utc_now().isoformat()));
    return chosen;
}

"""Why `classes` cannot be saved, or "" when they can."""
def classes_problem(classes: list[str]) -> str {
    unknown = [c for c in classes if c not in ASSET_CLASSES];
    if unknown {
        return f"Unknown asset class: {', '.join(sorted(set(str(u) for u in unknown)))}.";
    }
    if not clean_classes(classes) {
        return "Choose at least one asset class.";
    }
    return "";
}

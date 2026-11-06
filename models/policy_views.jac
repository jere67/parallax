"""What the policy endpoints return (policy/api.jac): a policy with its words and history, the
catalog an editor is built from, a replay of a stored run under a policy, and the chat."""
import from models.policy { Knob, Metric, Policy }

"""One rule effect an editor offers: its value and the words a sentence starts with."""
obj EffectView {
    has value: str,
        lead: str;
}

"""One way to compare a metric: its value and words, and whether it takes words, not a number."""
obj OpView {
    has value: str,
        label: str,
        words: bool;
}

"""Everything an editor needs that only the server knows: every knob and its range, every
metric a rule can read, the effects and comparisons, and the default policy."""
obj PolicyCatalog {
    has knobs: list[Knob],
        groups: list[str],
        metrics: list[Metric],
        effects: list[EffectView],
        ops: list[OpView],
        defaults: Policy;
    has max_rules: int = 0,
        max_conditions: int = 0;
}

"""One saved version as a reader sees it."""
obj VersionView {
    has version: int,
        saved_at: str;
    has author: str = "",
        source: str = "",
        note: str = "",
        changes: list[str] = [];
}

"""A policy in force: version 0 is the defaults, with nothing saved. `sentences` say what it
does, and `rule_sentences` say each rule's condition, in the order of `policy.rules`."""
obj PolicyDoc {
    has scope: str,
        version: int,
        policy: Policy;
    has saved_at: str = "",
        sentences: list[str] = [],
        rule_sentences: list[str] = [],
        history: list[VersionView] = [];
}

"""What a save did, and the policy now in force."""
obj PolicySaveReply {
    has saved: bool,
        version: int,
        message: str;
    has problems: list[str] = [],
        changes: list[str] = [],
        doc: PolicyDoc | None = None;
}

"""One covered ticker in a replay: what the team decided and what the policy would. `notes`
say how the rules changed its action, and `skipped` which could not be checked. `unreviewed`
marks a buy the Arbiter never saw, since the team's rule did not propose one."""
obj ReplayRow {
    has ticker: str,
        team_action: str,
        action: str;
    has sector: str = "",
        held: bool = False,
        score: float | None = None,
        agreement: float | None = None,
        conviction: float = 0.0,
        changed: bool = False,
        notes: list[str] = [],
        skipped: list[str] = [],
        unreviewed: bool = False;
}

"""A stored run under a policy, moving no money and calling no model. `problems` are why a
draft could not be replayed; `differs` counts tickers whose action differs from the team's;
`sentences` and `rule_sentences` say the draft in words, so an editor can show them as it changes."""
obj ReplayView {
    has run_date: str = "",
        previous_day: str = "",
        next_day: str = "",
        demo: bool = False,
        team_version: int = 0,
        rows: list[ReplayRow] = [],
        differs: int = 0,
        counts: dict[str, int] = {},
        team_counts: dict[str, int] = {},
        problems: list[str] = [],
        sentences: list[str] = [],
        rule_sentences: list[str] = [];
}

"""A signed-in user's page: their own policy, the team's, and whether they may edit the team's."""
obj PolicyWorkspace {
    has mine: PolicyDoc,
        team: PolicyDoc;
    has can_edit_team: bool = False;
}

"""One message in the policy chat. An assistant turn with `changes` is a proposal: `status`
says whether it is "proposed", "applied", "discarded", "stale", or "invalid"."""
obj ChatTurnView {
    has id: str,
        role: str,
        text: str,
        at: str;
    has changes: list[str] = [],
        problems: list[str] = [],
        impact: list[str] = [],
        status: str = "",
        applied_version: int = 0;
}

"""A user's chat about one policy. `pending` is true while a message is being answered, so the
client asks again shortly. `available` is false when no new message can be sent, and `note`
says why; the form and the rest of the page work regardless."""
obj ChatState {
    has scope: str;
    has turns: list[ChatTurnView] = [],
        pending: bool = False,
        available: bool = False,
        note: str = "",
        remaining: int = 0,
        daily_limit: int = 0;
}

"""What applying or discarding a proposal did. `doc` is the policy now in force."""
obj ChatActionReply {
    has ok: bool,
        message: str,
        chat: ChatState;
    has doc: PolicyDoc | None = None;
}

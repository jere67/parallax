"""Trading policies (TDD §7, policy): when to buy, sell, trim, and hold, and the limits a run
sizes and gates with, as the team or one user wants them.

    root.shared ──> PolicyVersion(scope team)      the team policy's versions
    user root   ──> PolicyVersion(scope personal)  one user's policy's versions
    user root   ──> ChatTurn                       that user's policy chat

A policy is never edited in place. Saving one adds a PolicyVersion numbered one past the
newest, so every version stays on record and the policy in force is the newest one. A run
records the team version it decided with, and its orders are sized and gated with the same
version even if the policy changes before they are placed.

A policy has two parts: bounded numbers (the decision thresholds, sizing, and risk limits;
analysis/policy.jac holds their ranges) and rules, each a list of conditions on a fixed set
of metrics with one effect. Rules are data, never code or free text, so the same policy always
gives the same decision.

This module's path is frozen for the same reason as models/graph.jac: moving a node type
quarantines its stored rows.
"""

"""What a rule does when its conditions hold.

- AVOID_BUY: no BUY or ADD while the conditions all hold.
- BUY_ONLY_IF: a BUY or ADD only while the conditions all hold.
- SELL: exit a held position while the conditions all hold.
- TRIM: sell part of a held position while the conditions all hold.
- KEEP: hold a position the thresholds or its time stop would sell or trim, while the
  conditions all hold. A SELL or TRIM rule still wins over it."""
enum RuleEffect: str {
    AVOID_BUY = "avoid_buy",
    BUY_ONLY_IF = "buy_only_if",
    SELL = "sell",
    TRIM = "trim",
    KEEP = "keep"
}

enum Op: str {
    LT = "lt",
    LE = "le",
    GT = "gt",
    GE = "ge",
    IN = "in",
    NOT_IN = "not_in"
}

enum PolicyScope: str {
    TEAM = "team",
    PERSONAL = "personal"
}

"""One test on a metric: a number for the comparisons, the allowed words for IN and NOT_IN.
Percent metrics are fractions (0.08 is 8%)."""
obj Condition {
    has metric: str,
        op: Op;
    has number: float | None = None,
        words: list[str] = [];
}

"""A rule: its effect applies while every condition holds. `label` is the user's own name for
it; `enabled` lets a rule be kept but paused."""
obj PolicyRule {
    has id: str,
        effect: RuleEffect,
        conditions: list[Condition];
    has label: str = "",
        enabled: bool = True;
}

"""The whole policy. The defaults are TDD §7's decision rule and §8's sizing and risk gate, so
a team with no saved version trades exactly as before."""
obj Policy {
    has buy_score: float = 0.2,
        buy_agreement: float = 0.5,
        sell_score: float = -0.25,
        trim_agreement: float = 0.5,
        time_stop: bool = True,
        sizing_scale: float = 0.08,
        trim_fraction: float = 0.5,
        max_position_weight: float = 0.10,
        sector_cap: float = 0.30,
        gross_limit: float = 0.90,
        regime_gross_limit: float = 0.50,
        new_positions_per_day: int = 3,
        turnover_limit: float = 0.25,
        drawdown_halt: float = 0.10,
        earnings_blackout_sessions: int = 2,
        stop_atr_multiple: float = 2.0;
    has rules: list[PolicyRule] = [];
}

"""A number a policy sets: its range, step, and unit ("score", "share", "count", "multiple",
"sessions", "switch"), and what it means. `int_valued` knobs take whole numbers."""
obj Knob {
    has name: str,
        label: str,
        group: str,
        low: float,
        high: float,
        step: float,
        unit: str,
        help: str;
    has int_valued: bool = False;
}

enum MetricKind: str {
    SCORE = "score",
    SHARE = "share",
    NUMBER = "number",
    COUNT = "count",
    CATEGORY = "category"
}

"""A fact a rule can test. `low` and `high` bound the values a condition may compare it to;
`choices` lists the words a category takes (empty for tickers, checked by pattern);
`held_only` metrics exist only for a held stock."""
obj Metric {
    has name: str,
        label: str,
        group: str,
        kind: MetricKind,
        help: str;
    has low: float = -1.0e9,
        high: float = 1.0e9,
        choices: list[str] = [],
        held_only: bool = False;
}

"""One saved version of a policy. `source` says how it was saved ("form", "chat",
"restore"); `note` is the saver's reason, or the chat message that proposed it; `changes`
lists what differs from the version before, in words."""
node PolicyVersion {
    has scope: PolicyScope,
        version: int,
        policy: Policy,
        saved_at: str;
    has author: str = "",
        source: str = "form",
        note: str = "",
        changes: list[str] = [];
}

"""A condition as the policy assistant drafts it, before code checks it: the metric and
operator are plain strings, and code refuses any it does not know."""
obj ConditionDraft {
    has metric: str,
        op: str;
    has number: float | None = None,
        words: list[str] = [];
}

enum EditKind: str {
    SET = "set",
    ADD_RULE = "add_rule",
    REMOVE_RULE = "remove_rule",
    PAUSE_RULE = "pause_rule",
    RESUME_RULE = "resume_rule"
}

"""One change the policy assistant proposes. SET gives `setting` a new `value` (1 or 0 for a
yes-or-no setting); ADD_RULE adds a rule with `effect`, `conditions`, and `label`; the other
kinds name an existing rule by `rule_id`."""
obj PolicyEdit {
    has kind: EditKind;
    has setting: str = "",
        value: float | None = None,
        effect: str = "",
        conditions: list[ConditionDraft] = [],
        label: str = "",
        rule_id: str = "";
}

sem PolicyEdit.kind = "set changes a setting; add_rule adds a rule; remove_rule, pause_rule, and resume_rule act on an existing rule.";
sem PolicyEdit.setting = "For set: the setting's name, exactly as in the settings list.";
sem PolicyEdit.value = "For set: the new value. Shares are fractions, so 8% is 0.08. For a switch, 1 is on and 0 is off.";
sem PolicyEdit.effect = "For add_rule: avoid_buy, buy_only_if, sell, trim, or keep.";
sem PolicyEdit.conditions = "For add_rule: the tests, all of which must hold for the rule to apply.";
sem PolicyEdit.label = "For add_rule: a name for the rule of at most six words.";
sem PolicyEdit.rule_id = "For remove_rule, pause_rule, and resume_rule: the rule's id, such as R2.";
sem ConditionDraft.metric = "The metric's name, exactly as in the metrics list.";
sem ConditionDraft.op = "lt, le, gt, or ge with a number; in or not_in with words.";
sem ConditionDraft.number = "The number to compare with. Metrics marked as a share are fractions, so 8% is 0.08.";
sem ConditionDraft.words = "The words to compare with, from the metric's choices, or tickers for the ticker metric.";

"""One message in a user's policy chat. A user turn holds what they wrote. An assistant turn
holds the reply and, when it proposed changes, the policy they would give (`proposal`),
checked by code: `changes` says what would change, `problems` why it cannot be applied, and
`status` whether it is "proposed", "applied", "discarded", "stale" (the policy changed
since), or "invalid". `base_version` is the version the proposal was drafted against, `impact`
says what it would change in the latest run, and `question` is the message it answers. A user
turn's `status` is "pending" until it is answered, then "answered" or "failed"; only a failed
one gives its place in the day's limit back."""
node ChatTurn {
    has scope: PolicyScope,
        role: str,
        text: str,
        at: str;
    has proposal: Policy | None = None,
        base_version: int = 0,
        changes: list[str] = [],
        problems: list[str] = [],
        impact: list[str] = [],
        question: str = "",
        status: str = "",
        applied_version: int = 0,
        model: str = "",
        requests: int = 0;
}

"""What the policy chat does with a model's edits: code applies them to a copy and holds them
to the form's limits, and normalizes the words a model may spell its own way."""
import from models.policy { ConditionDraft, EditKind, Op, Policy, PolicyEdit, PolicyRule, Condition, RuleEffect }
import from policy.chat { apply_edits, metrics_text, normal_words, rules_text, settings_text }

test "edits apply to a copy, and the original policy never changes" {
    start = Policy();
    (found, problems) = apply_edits(start, [
        PolicyEdit(kind=EditKind.SET, setting="buy_score", value=0.4),
        PolicyEdit(kind=EditKind.ADD_RULE, effect="avoid_buy", label="Too hot", conditions=[ConditionDraft(metric="rsi_14", op="gt", number=70.0)])
    ]);
    assert problems == [];
    assert start.buy_score == 0.2 and start.rules == [];
    assert found.buy_score == 0.4 and found.rules[0].id == "R1" and found.rules[0].effect == RuleEffect.AVOID_BUY;
    assert found.rules[0].conditions[0].op == Op.GT and found.rules[0].label == "Too hot";
}

test "a setting past its limit, or a rule that does not exist, is a problem, not a change" {
    (_, over) = apply_edits(Policy(), [PolicyEdit(kind=EditKind.SET, setting="max_position_weight", value=0.5)]);
    assert over and "Largest position" in over[0];
    (_, missing) = apply_edits(Policy(), [PolicyEdit(kind=EditKind.REMOVE_RULE, rule_id="R9")]);
    assert missing == ["There is no rule R9."];
    (_, bad_metric) = apply_edits(Policy(), [PolicyEdit(kind=EditKind.ADD_RULE, effect="sell", conditions=[ConditionDraft(metric="rsi_14", op="gt", number=5000.0)])]);
    assert bad_metric;
}

test "pausing, resuming, and removing act on the named rule" {
    rule = PolicyRule(id="R1", effect=RuleEffect.SELL, conditions=[Condition(metric="return_since_entry", op=Op.LT, number=-0.08)]);
    start = Policy(rules=[rule]);
    (paused, _) = apply_edits(start, [PolicyEdit(kind=EditKind.PAUSE_RULE, rule_id="R1")]);
    assert not paused.rules[0].enabled and start.rules[0].enabled;
    (resumed, _) = apply_edits(paused, [PolicyEdit(kind=EditKind.RESUME_RULE, rule_id=" R1 ")]);
    assert resumed.rules[0].enabled;
    (gone, _) = apply_edits(start, [PolicyEdit(kind=EditKind.REMOVE_RULE, rule_id="R1")]);
    assert gone.rules == [];
    assert "R1: " in rules_text(start) and "(paused)" in rules_text(paused);
}

test "words take the catalog's spelling: capitals for tickers, its own case for categories" {
    assert normal_words("ticker", [" aapl ", "brk.b"]) == ["AAPL", "BRK-B"];
    assert normal_words("sector", ["energy", "information technology"]) == ["Energy", "Information Technology"];
    assert normal_words("sector", ["not a sector"]) == ["not a sector"];
    (_, problems) = apply_edits(Policy(), [PolicyEdit(kind=EditKind.ADD_RULE, effect="avoid_buy", conditions=[ConditionDraft(metric="sector", op="in", words=["not a sector"])])]);
    assert problems;
}

test "the brief lists every setting with its limits, and every metric with its range" {
    text = settings_text(Policy());
    assert "max_position_weight = 10% (limits 1% to 15%)" in text;
    assert "buy_score" in text and "time_stop" in text;
    metrics = metrics_text();
    assert "rsi_14" in metrics and "Energy" in metrics and "any ticker" in metrics;
}

"""The assistant's typed answer with MockLLM standing in for the model: a malformed edit is sent
back for one retry, and a question needs no edits. Run serially."""
import json;
import agents.policy_assistant as module;
import from jaclang.byllm.lib { MockLLM, MockRawResponse, OutputConversionError }
import from agents.policy_assistant { PolicyAnswer, answer_policy_message, edit_problem }
import from models.policy { ConditionDraft, EditKind, Op, PolicyEdit, RuleEffect }

def ask_with(outputs: list[str]) -> tuple[PolicyAnswer, MockLLM] {
    mock = MockLLM(model_name="mock-policy", config={"outputs": [MockRawResponse(content=o) for o in outputs]});
    saved = module.policy_llm;
    setattr(module, "policy_llm", mock);
    try {
        return (answer_policy_message("Avoid hot stocks", "Mine", "None", "buy_score = 0.20", "rsi_14", "No run", "None yet."), mock);
    } finally {
        setattr(module, "policy_llm", saved);
    }
}

def answer(edits: list[dict[str, any]]) -> str {
    return json.dumps({"reply": "Here is a rule.", "edits": edits});
}

test "an answer to a question has no edits" {
    (found, _) = ask_with([json.dumps({"reply": "AAPL scored 0.1, under your bar.", "edits": []})]);
    assert found.edits == [] and "0.1" in found.reply;
}

test "a valid edit parses into typed fields" {
    edit = {"kind": "add_rule", "effect": "avoid_buy", "label": "Too hot", "conditions": [{"metric": "rsi_14", "op": "gt", "number": 70}]};
    (found, _) = ask_with([answer([edit])]);
    assert found.edits[0].kind == EditKind.ADD_RULE and found.edits[0].conditions[0].metric == "rsi_14";
}

test "an unknown metric is sent back, and the retry's answer is used" {
    bad = {"kind": "add_rule", "effect": "avoid_buy", "conditions": [{"metric": "made_up", "op": "gt", "number": 70}]};
    good = {"kind": "set", "setting": "buy_score", "value": 0.3};
    (found, _) = ask_with([answer([bad]), answer([good])]);
    assert found.edits[0].kind == EditKind.SET and found.edits[0].value == 0.3;
}

test "a second malformed answer is an error, for the caller to report" {
    bad = {"kind": "set", "setting": "made_up", "value": 1};
    failed = False;
    try {
        ask_with([answer([bad]), answer([bad])]);
    } except OutputConversionError {
        failed = True;
    }
    assert failed;
}

test "an effect or operator outside the lists is sent back, and the retry's answer is used" {
    good = {"kind": "add_rule", "effect": "sell", "conditions": [{"metric": "rsi_14", "op": "gt", "number": 70}]};
    bad_op = {"kind": "add_rule", "effect": "sell", "conditions": [{"metric": "rsi_14", "op": ">", "number": 70}]};
    bad_effect = {"kind": "add_rule", "effect": "no_buy", "conditions": [{"metric": "rsi_14", "op": "gt", "number": 70}]};
    for bad in [bad_op, bad_effect] {
        (found, _) = ask_with([answer([bad]), answer([good])]);
        assert found.edits[0].effect == RuleEffect.SELL and found.edits[0].conditions[0].op == Op.GT;
    }
}

# A built .jab loads no `sem` text, so this has to hold in the prompt itself. A real free model
# guessed at effects and operators until it did: docs/TDD.md §7.
test "the prompt itself says how to write every kind of edit" {
    (_, mock) = ask_with([answer([])]);
    prompt = mock.seen_prompts[0];
    for word in [k.value for k in [*EditKind]] + [e.value for e in [*RuleEffect]] {
        assert word in prompt, word;
    }
    assert "With lt, le, gt," in prompt and "or ge, give a number" in prompt and "With in or not_in, give words" in prompt;
    assert "8% is 0.08" in prompt and "rule_id" in prompt;
    assert "return_since_entry ge 0.3" in prompt;
}

test "edit_problem names what is wrong with an edit's shape" {
    assert "does not exist" in edit_problem(PolicyEdit(kind=EditKind.SET, setting="nope", value=1.0));
    assert "needs a value" in edit_problem(PolicyEdit(kind=EditKind.SET, setting="buy_score"));
    assert "needs an effect" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE));
    assert "at least one" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect=RuleEffect.SELL));
    assert "needs a number" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect=RuleEffect.SELL, conditions=[ConditionDraft(metric="rsi_14", op=Op.GT)]));
    assert "needs words" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect=RuleEffect.SELL, conditions=[ConditionDraft(metric="sector", op=Op.IN)]));
    assert "rule_id" in edit_problem(PolicyEdit(kind=EditKind.PAUSE_RULE));
    assert edit_problem(PolicyEdit(kind=EditKind.PAUSE_RULE, rule_id="R1")) == "";
}

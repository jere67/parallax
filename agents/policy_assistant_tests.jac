"""The assistant's typed answer with MockLLM standing in for the model: a malformed edit is sent
back for one retry, and a question needs no edits. Run serially."""
import json;
import agents.policy_assistant as module;
import from jaclang.byllm.lib { MockLLM, MockRawResponse, OutputConversionError }
import from agents.policy_assistant { PolicyAnswer, answer_policy_message, edit_problem }
import from models.policy { ConditionDraft, EditKind, PolicyEdit }

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

def answer(edits: list[dict]) -> str {
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

test "edit_problem names what is wrong with an edit's shape" {
    assert "does not exist" in edit_problem(PolicyEdit(kind=EditKind.SET, setting="nope", value=1.0));
    assert "needs a value" in edit_problem(PolicyEdit(kind=EditKind.SET, setting="buy_score"));
    assert "effect" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect="explode"));
    assert "at least one" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect="sell"));
    assert "op" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect="sell", conditions=[ConditionDraft(metric="rsi_14", op="bigger")]));
    assert "needs a number" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect="sell", conditions=[ConditionDraft(metric="rsi_14", op="gt")]));
    assert "needs words" in edit_problem(PolicyEdit(kind=EditKind.ADD_RULE, effect="sell", conditions=[ConditionDraft(metric="sector", op="in")]));
    assert "rule_id" in edit_problem(PolicyEdit(kind=EditKind.PAUSE_RULE));
    assert edit_problem(PolicyEdit(kind=EditKind.PAUSE_RULE, rule_id="R1")) == "";
}

"""The policy engine: the default policy is the TDD decision rule, rules change actions in
their fixed order, unknown facts skip a rule instead of guessing, and no policy passes its
hard limits."""
import random;
import from analysis.consensus { Consensus, ConsensusConfig, decide }
import from analysis.policy {
    Facts,
    KNOBS,
    KNOB_BY_NAME,
    METRICS,
    MAX_RULES,
    changes,
    clamp_knob,
    consensus_config,
    describe,
    evaluate,
    gate_config,
    next_rule_id,
    rule_sentence,
    sizing_config,
    validate,
    with_knob
}
import from models.graph { TradeAction }
import from models.policy { Condition, Op, Policy, PolicyRule, RuleEffect }

def panel(score: float, agreement: float = 0.8, ci_low: float | None = None) -> Consensus {
    low = ci_low if ci_low is not None else score - 0.1;
    return Consensus(score=score, agreement=agreement, ci_low=low, ci_high=score + 0.1);
}

def rule(id: str, effect: RuleEffect, conditions: list[Condition], label: str = "") -> PolicyRule {
    return PolicyRule(id=id, effect=effect, conditions=conditions, label=label);
}

def above(metric: str, number: float) -> Condition {
    return Condition(metric=metric, op=Op.GT, number=number);
}

def below(metric: str, number: float) -> Condition {
    return Condition(metric=metric, op=Op.LT, number=number);
}

def facts(numbers: dict[str, float] = {}, words: dict[str, str] = {}) -> Facts {
    return Facts(numbers=dict(numbers), words=dict(words));
}

test "the default policy decides exactly as the consensus engine's rule" {
    rng = random.Random(7);
    for _ in range(3000) {
        score = round(rng.uniform(-1.0, 1.0), 3);
        agreement = round(rng.random(), 3);
        low = round(score - rng.random() * 0.4, 3);
        held = rng.random() < 0.5;
        due = rng.random() < 0.2;
        found = evaluate(Policy(), facts(), held, Consensus(score=score, agreement=agreement, ci_low=low, ci_high=score), due);
        assert found.action == decide(score, agreement, low, held, due and held, ConsensusConfig());
        assert found.base == found.action and not found.steps and not found.skipped;
    }
}

test "the thresholds come from the policy" {
    strict = Policy(buy_score=0.5, buy_agreement=0.8);
    assert evaluate(Policy(), facts(), False, panel(0.3)).action == TradeAction.BUY;
    assert evaluate(strict, facts(), False, panel(0.3)).action == TradeAction.NO_ACTION;
    assert evaluate(strict, facts(), False, panel(0.6, 0.9)).action == TradeAction.BUY;
    assert evaluate(Policy(sell_score=-0.1), facts(), True, panel(-0.15)).action == TradeAction.SELL;
    assert evaluate(Policy(), facts(), True, panel(-0.15, 0.4)).action == TradeAction.TRIM;
}

test "an avoid rule blocks a buy and an add, and says why" {
    p = Policy(rules=[rule("R1", RuleEffect.AVOID_BUY, [above("rsi_14", 70.0)], "Overbought")]);
    hot = facts({"rsi_14": 74.2});
    buy = evaluate(p, hot, False, panel(0.4));
    assert (buy.base, buy.action) == (TradeAction.BUY, TradeAction.NO_ACTION);
    assert buy.changed() and len(buy.steps) == 1 and buy.steps[0].rule_id == "R1";
    assert "RSI(14) 74.2" in buy.steps[0].detail and "\"Overbought\"" in buy.steps[0].detail;
    assert evaluate(p, hot, True, panel(0.4)).action == TradeAction.HOLD;
    assert evaluate(p, facts({"rsi_14": 60.0}), False, panel(0.4)).action == TradeAction.BUY;
    # A rule on entries never touches a sell.
    assert evaluate(p, hot, True, panel(-0.5)).action == TradeAction.SELL;
}

test "a buy-only-if rule blocks a buy when it fails" {
    p = Policy(rules=[rule("R1", RuleEffect.BUY_ONLY_IF, [above("fundamentals_score", 0.0)])]);
    assert evaluate(p, facts({"fundamentals_score": 0.3}), False, panel(0.4)).action == TradeAction.BUY;
    assert evaluate(p, facts({"fundamentals_score": -0.1}), False, panel(0.4)).action == TradeAction.NO_ACTION;
}

test "a rule with a missing fact is skipped and noted, never guessed" {
    p = Policy(rules=[
        rule("R1", RuleEffect.AVOID_BUY, [above("rsi_14", 70.0)]),
        rule("R2", RuleEffect.BUY_ONLY_IF, [above("flow_score", 0.0)])
    ]);
    found = evaluate(p, facts(), False, panel(0.4));
    assert found.action == TradeAction.BUY and not found.steps;
    assert len(found.skipped) == 2;
    assert "no RSI(14)" in found.skipped[0] and "no Flow specialist's score" in found.skipped[1];
    # A false condition settles the rule even when another is unknown.
    both = Policy(rules=[rule("R1", RuleEffect.AVOID_BUY, [above("rsi_14", 70.0), Condition(metric="sector", op=Op.IN, words=["Energy"])])]);
    settled = evaluate(both, facts(words={"sector": "Utilities"}), False, panel(0.4));
    assert settled.action == TradeAction.BUY and not settled.skipped;
}

test "category conditions match words, ignoring case" {
    p = Policy(rules=[rule("R1", RuleEffect.AVOID_BUY, [Condition(metric="sector", op=Op.IN, words=["Energy", "Utilities"])])]);
    assert evaluate(p, facts(words={"sector": "energy"}), False, panel(0.4)).action == TradeAction.NO_ACTION;
    assert evaluate(p, facts(words={"sector": "Financials"}), False, panel(0.4)).action == TradeAction.BUY;
    q = Policy(rules=[rule("R1", RuleEffect.BUY_ONLY_IF, [Condition(metric="regime", op=Op.NOT_IN, words=["RISK_OFF"])])]);
    assert evaluate(q, facts(words={"regime": "RISK_OFF"}), False, panel(0.4)).action == TradeAction.NO_ACTION;
}

test "exit rules sell or trim a held stock, override buys, and come last" {
    stop = rule("R1", RuleEffect.SELL, [below("return_since_entry", -0.08)], "Stop loss");
    take = rule("R2", RuleEffect.TRIM, [above("return_since_entry", 0.25)]);
    keep = rule("R3", RuleEffect.KEEP, [above("sessions_held", 0.0)]);
    p = Policy(rules=[keep, take, stop]);
    down = facts({"return_since_entry": -0.12, "sessions_held": 4.0});
    found = evaluate(p, down, True, panel(0.4));
    assert (found.base, found.action) == (TradeAction.ADD, TradeAction.SELL);
    assert "-12%" in found.steps[-1].detail;
    up = evaluate(p, facts({"return_since_entry": 0.3, "sessions_held": 4.0}), True, panel(0.1));
    assert up.action == TradeAction.TRIM;
    # A stock that is not held takes no exit rule.
    assert evaluate(p, down, False, panel(0.4)).action == TradeAction.BUY;
    # A sell rule wins over a trim rule.
    both = Policy(rules=[rule("R1", RuleEffect.TRIM, [above("sessions_held", 1.0)]), rule("R2", RuleEffect.SELL, [above("sessions_held", 1.0)])]);
    assert evaluate(both, facts({"sessions_held": 5.0}), True, panel(0.0)).action == TradeAction.SELL;
}

test "a keep rule holds a threshold or time-stop sell, but never an exit rule's" {
    keep = rule("R1", RuleEffect.KEEP, [above("fundamentals_score", 0.2)]);
    strong = facts({"fundamentals_score": 0.5, "return_since_entry": -0.2});
    p = Policy(rules=[keep]);
    sold = evaluate(p, strong, True, panel(-0.5));
    assert (sold.base, sold.action) == (TradeAction.SELL, TradeAction.HOLD);
    assert "from the thresholds" in sold.steps[0].detail;
    timed = evaluate(p, strong, True, panel(0.0), True);
    assert (timed.base, timed.action) == (TradeAction.SELL, TradeAction.HOLD);
    assert "time stop" in timed.steps[0].detail;
    assert evaluate(p, strong, True, panel(0.0, 0.3)).action == TradeAction.HOLD;
    with_stop = Policy(rules=[keep, rule("R2", RuleEffect.SELL, [below("return_since_entry", -0.1)])]);
    assert evaluate(with_stop, strong, True, panel(-0.5)).action == TradeAction.SELL;
}

test "time stops can be turned off" {
    assert evaluate(Policy(), facts(), True, panel(0.0), True).action == TradeAction.SELL;
    assert evaluate(Policy(time_stop=False), facts(), True, panel(0.0), True).action == TradeAction.HOLD;
}

test "a forced hold takes only exit rules" {
    p = Policy(rules=[
        rule("R1", RuleEffect.BUY_ONLY_IF, [above("score", 0.9)]),
        rule("R2", RuleEffect.SELL, [below("return_since_entry", -0.1)])
    ]);
    assert evaluate(p, facts({"return_since_entry": -0.2}), True, None).action == TradeAction.SELL;
    assert evaluate(p, facts({"return_since_entry": -0.2}), True, panel(0.5), forced=True).action == TradeAction.SELL;
    held = evaluate(p, facts({"return_since_entry": 0.0}), True, None);
    assert held.action == TradeAction.HOLD and not held.steps;
    assert evaluate(p, facts(), False, None).action == TradeAction.HOLD;
}

test "a paused rule does nothing" {
    r = rule("R1", RuleEffect.AVOID_BUY, [above("rsi_14", 70.0)]);
    r.enabled = False;
    assert evaluate(Policy(rules=[r]), facts({"rsi_14": 90.0}), False, panel(0.4)).action == TradeAction.BUY;
}

test "the default policy is valid and every knob's default is inside its range" {
    assert validate(Policy()) == [];
    for k in KNOBS {
        value = float(getattr(Policy(), k.name));
        assert k.low <= value <= k.high, k.name;
    }
    assert len({m.name for m in METRICS}) == len(METRICS);
}

test "no policy can loosen a limit past its ceiling" {
    for (name, value) in [("max_position_weight", 0.25), ("sector_cap", 0.6), ("gross_limit", 1.0), ("new_positions_per_day", 9.0), ("drawdown_halt", 0.5), ("turnover_limit", 0.9), ("stop_atr_multiple", 0.5), ("earnings_blackout_sessions", 0.0), ("buy_score", 0.0), ("sell_score", 0.1)] {
        problems = validate(with_knob(Policy(), name, value));
        assert len(problems) >= 1, name;
        assert KNOB_BY_NAME[name].label in problems[0], problems;
    }
    assert validate(Policy(max_position_weight=0.15, gross_limit=0.10)) != [];
}

test "rules are checked against the metric catalog" {
    def problems_of(c: Condition) -> list[str] {
        return validate(Policy(rules=[rule("R1", RuleEffect.AVOID_BUY, [c])]));
    }
    assert "not a metric" in problems_of(Condition(metric="pe_ratio", op=Op.GT, number=30.0))[0];
    assert "\"is\" or \"is not\"" in problems_of(Condition(metric="sector", op=Op.GT, number=1.0))[0];
    assert "not a sector" in problems_of(Condition(metric="sector", op=Op.IN, words=["Tech"]))[0];
    assert "not a ticker" in problems_of(Condition(metric="ticker", op=Op.IN, words=["apple inc"]))[0];
    assert "compared with a number" in problems_of(Condition(metric="rsi_14", op=Op.IN, words=["70"]))[0];
    assert "never" in problems_of(Condition(metric="rsi_14", op=Op.GT, number=170.0))[0];
    assert problems_of(Condition(metric="ticker", op=Op.NOT_IN, words=["BRK.B", "AAPL"])) == [];
    assert validate(Policy(rules=[rule("R1", RuleEffect.SELL, [])])) == ["Rule R1 needs at least one condition."];
    dup = Policy(rules=[rule("R1", RuleEffect.SELL, [above("rsi_14", 80.0)]), rule("R1", RuleEffect.SELL, [above("rsi_14", 90.0)])]);
    assert "used twice" in validate(dup)[0];
    many = Policy(rules=[rule(f"R{i}", RuleEffect.SELL, [above("rsi_14", 80.0)]) for i in range(MAX_RULES + 1)]);
    assert any("at most" in p for p in validate(many));
}

test "the policy's numbers reach the consensus engine, sizing, and the risk gate" {
    p = Policy(buy_score=0.4, buy_agreement=0.7, sell_score=-0.5, trim_agreement=0.3, sizing_scale=0.05, trim_fraction=0.25, max_position_weight=0.05, sector_cap=0.2, gross_limit=0.6, regime_gross_limit=0.3, new_positions_per_day=1, turnover_limit=0.1, drawdown_halt=0.05, earnings_blackout_sessions=4, stop_atr_multiple=3.0);
    c = consensus_config(p, 1, 0);
    assert (c.samples, c.extra_samples, c.buy_score, c.buy_agreement, c.sell_score, c.trim_agreement) == (1, 0, 0.4, 0.7, -0.5, 0.3);
    s = sizing_config(p);
    assert (s.scale, s.max_position_weight, s.gross_exposure_limit, s.trim_fraction) == (0.05, 0.05, 0.6, 0.25);
    g = gate_config(p);
    assert (g.max_position_weight, g.sector_cap, g.gross_limit, g.regime_gross_limit, g.new_positions_per_day, g.turnover_limit, g.drawdown_halt, g.earnings_blackout_sessions, g.stop_atr_multiple) == (0.05, 0.2, 0.6, 0.3, 1, 0.1, 0.05, 4, 3.0);
    # Limits a policy does not set keep the gate's defaults.
    assert (g.min_price, g.adv_fraction) == (5.0, 0.01);
}

test "a policy reads as sentences, and a change as a list of edits" {
    p = Policy(rules=[rule("R1", RuleEffect.AVOID_BUY, [above("rsi_14", 70.0), Condition(metric="sector", op=Op.IN, words=["Energy", "Utilities"])])]);
    assert rule_sentence(p.rules[0]) == "Don't buy or add when RSI(14) is above 70 and sector is one of Energy, Utilities.";
    lines = describe(p);
    assert lines[0].startswith("Buy or add when the panel score is at least +0.20, at least 50% of samples agree");
    assert "time stop" in lines[1];
    assert lines[3] == rule_sentence(p.rules[0]);
    assert lines[-1] == "Sizing and risk limits are the defaults.";
    assert "largest position 5%" in describe(Policy(max_position_weight=0.05))[-1];
    stop = rule("R2", RuleEffect.SELL, [below("return_since_entry", -0.08)]);
    after = Policy(buy_score=0.3, time_stop=False, rules=[stop]);
    edits = changes(p, after);
    assert "Minimum panel score to buy: +0.20 → +0.30" in edits;
    assert "Sell when the time stop passes: on → off" in edits;
    assert "Added rule R2: Sell a held stock when return since entry is below -8%." in edits;
    assert any(e.startswith("Removed rule R1") for e in edits);
    assert changes(p, p) == [];
}

test "knob values clamp to their range and step, and rule ids never repeat" {
    k = KNOB_BY_NAME["max_position_weight"];
    assert clamp_knob(k, 0.4) == 0.15 and clamp_knob(k, 0.0) == 0.01 and clamp_knob(k, 0.064) == 0.06;
    assert clamp_knob(KNOB_BY_NAME["new_positions_per_day"], 2.6) == 3.0;
    assert with_knob(Policy(), "time_stop", 0.0).time_stop is False;
    assert with_knob(Policy(), "new_positions_per_day", 2.0).new_positions_per_day == 2;
    assert next_rule_id(Policy()) == "R1";
    assert next_rule_id(Policy(rules=[rule("R1", RuleEffect.SELL, []), rule("R4", RuleEffect.SELL, [])])) == "R5";
}

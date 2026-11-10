"""The policy engine (TDD §7, policy): plain code that applies a trading policy
(models/policy.jac) to one ticker's consensus and facts, checks a policy against its hard
limits, and says what a policy does and what changed between two versions, in words.

A ticker's action is settled in a fixed order, so the same policy and facts always give the
same action:

1. The policy's thresholds turn C, A, and the interval into the base action, exactly as the
   consensus engine's decision rule does (analysis/consensus.jac). A held position whose time
   stop has passed is sold, unless the policy turns time stops off.
2. Entry rules: an AVOID_BUY rule that holds, or a BUY_ONLY_IF rule that fails, turns a BUY
   into NO ACTION and an ADD into HOLD.
3. KEEP rules turn a SELL or TRIM that came from the thresholds or the time stop into HOLD.
4. Exit rules on a held position: a SELL rule that holds sells, and a TRIM rule trims anything
   short of a sell. They come last, so risk can always come off.

A condition whose metric is missing (an indicator older runs did not store, or a position
metric for a stock not held) is unknown. A rule with an unknown condition and no false one is
skipped, and the outcome says so; nothing is guessed. A ticker the panel could not decide
(a forced HOLD) still takes exit rules, since they only reduce risk.

Every number a policy sets has a range (KNOBS). The risk limits' ranges are hard ceilings: no
policy, saved by a person or proposed by the assistant, can loosen a limit past them.
"""
import math;
import re;
import from action.gate { GateConfig }
import from action.sizing { SizingConfig }
import from analysis.consensus { Consensus, ConsensusConfig, decide }
import from models.graph { TradeAction }
import from models.policy { Condition, Knob, Metric, MetricKind, Op, Policy, PolicyRule, RuleEffect }

# Bump with any change to how a policy is applied, so a decision can be traced to it.
glob POLICY_ENGINE_VERSION: str = "2026-11-05";

glob MAX_RULES: int = 20;
glob MAX_CONDITIONS: int = 5;
glob MAX_LABEL_CHARS: int = 80;
glob MAX_WORDS: int = 30;
glob TICKER_PATTERN: re.Pattern[str] = re.compile(r"^[A-Z]{1,5}([.-][A-Z]{1,2})?$");

glob KNOBS: list[Knob] = [
    Knob(name="buy_score", label="Minimum panel score to buy", group="Buying", low=0.05, high=1.0, step=0.05, unit="score", help="The panel's consensus score C, from -1 (all strong sells) to +1 (all strong buys), must reach this to buy or add."),
    Knob(name="buy_agreement", label="Minimum agreement to buy", group="Buying", low=0.3, high=1.0, step=0.05, unit="share", help="The share of specialist samples pointing the same way as C must reach this to buy or add."),
    Knob(name="sell_score", label="Panel score that sells", group="Selling", low=-1.0, high=-0.05, step=0.05, unit="score", help="A held stock is sold once C falls to this or below."),
    Knob(name="trim_agreement", label="Agreement below which a hold trims", group="Selling", low=0.0, high=1.0, step=0.05, unit="share", help="A held stock the panel does not back is trimmed instead of held when agreement falls below this."),
    Knob(name="time_stop", label="Sell when the time stop passes", group="Selling", low=0.0, high=1.0, step=1.0, unit="switch", help="Each buy sets a time stop from the horizon of the votes behind it; when on, the position is sold once it passes.", int_valued=True),
    Knob(name="trim_fraction", label="Share of a position a trim sells", group="Selling", low=0.1, high=1.0, step=0.05, unit="share", help="How much of a held position a TRIM sells."),
    Knob(name="sizing_scale", label="Sizing scale", group="Sizing", low=0.01, high=0.15, step=0.01, unit="share", help="A buy's target weight is this times its conviction, scaled down for volatile stocks, before the caps."),
    Knob(name="max_position_weight", label="Largest position", group="Limits", low=0.01, high=0.15, step=0.01, unit="share", help="No position may grow past this share of the portfolio."),
    Knob(name="sector_cap", label="Largest sector", group="Limits", low=0.05, high=0.40, step=0.01, unit="share", help="No sector may grow past this share of the portfolio."),
    Knob(name="gross_limit", label="Most invested", group="Limits", low=0.10, high=0.95, step=0.05, unit="share", help="Positions may total at most this share of the portfolio; the rest stays cash."),
    Knob(name="regime_gross_limit", label="Most invested in a risk-off market", group="Limits", low=0.0, high=0.50, step=0.05, unit="share", help="The cap on positions when SPY is below its 200-day average and volatile, or either figure is missing."),
    Knob(name="new_positions_per_day", label="New positions a day", group="Limits", low=0.0, high=5.0, step=1.0, unit="count", help="At most this many new stocks are bought in one day, highest conviction first.", int_valued=True),
    Knob(name="turnover_limit", label="Daily turnover", group="Limits", low=0.02, high=0.50, step=0.01, unit="share", help="Orders in one day may trade at most this share of the portfolio, sells first."),
    Knob(name="drawdown_halt", label="Drawdown that halts buying", group="Limits", low=0.02, high=0.20, step=0.01, unit="share", help="No new buys once the portfolio is this far below its peak; sells and stops still run."),
    Knob(name="earnings_blackout_sessions", label="Earnings blackout", group="Limits", low=1.0, high=10.0, step=1.0, unit="sessions", help="No new entry this many trading sessions or fewer before an earnings release.", int_valued=True),
    Knob(name="stop_atr_multiple", label="Protective stop distance", group="Limits", low=1.0, high=4.0, step=0.25, unit="multiple", help="Every entry gets a stop this many ATR(14) below its price.")
];

glob KNOB_GROUPS: list[str] = ["Buying", "Selling", "Sizing", "Limits"];

glob SECTORS: list[str] = [
    "Communication Services",
    "Consumer Discretionary",
    "Consumer Staples",
    "Energy",
    "Financials",
    "Health Care",
    "Industrials",
    "Information Technology",
    "Materials",
    "Real Estate",
    "Utilities"
];
glob REGIMES: list[str] = ["RISK_ON", "NEUTRAL", "RISK_OFF"];

glob METRICS: list[Metric] = [
    Metric(name="score", label="panel score", group="Panel", kind=MetricKind.SCORE, help="The consensus score C, from -1 to +1.", low=-1.0, high=1.0),
    Metric(name="agreement", label="panel agreement", group="Panel", kind=MetricKind.SHARE, help="The share of samples pointing the same way as C.", low=0.0, high=1.0),
    Metric(name="ci_low", label="low end of the score's interval", group="Panel", kind=MetricKind.SCORE, help="The low end of the 80% bootstrap interval for C.", low=-1.0, high=1.0),
    Metric(name="conviction", label="conviction", group="Panel", kind=MetricKind.SCORE, help="|C| × A, from 0 to 1.", low=0.0, high=1.0),
    Metric(name="fundamentals_score", label="Fundamentals specialist's score", group="Specialists", kind=MetricKind.SCORE, help="The Fundamentals specialist's mean signed vote, from -1 to +1.", low=-1.0, high=1.0),
    Metric(name="technical_score", label="Technical specialist's score", group="Specialists", kind=MetricKind.SCORE, help="The Technical specialist's mean signed vote, from -1 to +1.", low=-1.0, high=1.0),
    Metric(name="news_score", label="News specialist's score", group="Specialists", kind=MetricKind.SCORE, help="The News specialist's mean signed vote, from -1 to +1.", low=-1.0, high=1.0),
    Metric(name="macro_score", label="Macro specialist's score", group="Specialists", kind=MetricKind.SCORE, help="The Macro specialist's mean signed vote, from -1 to +1.", low=-1.0, high=1.0),
    Metric(name="flow_score", label="Flow specialist's score", group="Specialists", kind=MetricKind.SCORE, help="The Flow specialist's mean signed vote, from -1 to +1; missing when it abstained.", low=-1.0, high=1.0),
    Metric(name="rsi_14", label="RSI(14)", group="Price", kind=MetricKind.NUMBER, help="The 14-day relative strength index, from 0 to 100; above 70 is often called overbought.", low=0.0, high=100.0),
    Metric(name="momentum_20", label="20-session return", group="Price", kind=MetricKind.SHARE, help="The stock's return over the last 20 sessions.", low=-1.0, high=5.0),
    Metric(name="momentum_60", label="60-session return", group="Price", kind=MetricKind.SHARE, help="The stock's return over the last 60 sessions.", low=-1.0, high=5.0),
    Metric(name="price_vs_sma_50", label="price against its 50-day average", group="Price", kind=MetricKind.SHARE, help="How far the last close is above (+) or below (-) its 50-day average.", low=-1.0, high=5.0),
    Metric(name="price_vs_sma_200", label="price against its 200-day average", group="Price", kind=MetricKind.SHARE, help="How far the last close is above (+) or below (-) its 200-day average.", low=-1.0, high=5.0),
    Metric(name="range_52w_position", label="place in its 52-week range", group="Price", kind=MetricKind.SHARE, help="0 at the 52-week low, 1 at the 52-week high.", low=0.0, high=1.0),
    Metric(name="rs_spy_20", label="20-session return against SPY", group="Price", kind=MetricKind.SHARE, help="The 20-session return relative to SPY's.", low=-1.0, high=5.0),
    Metric(name="realized_vol_20", label="20-day volatility", group="Risk", kind=MetricKind.SHARE, help="Annualized 20-day realized volatility.", low=0.0, high=5.0),
    Metric(name="atr_pct", label="ATR as a share of price", group="Risk", kind=MetricKind.SHARE, help="ATR(14) divided by the last close: the typical daily range.", low=0.0, high=1.0),
    Metric(name="sessions_to_earnings", label="sessions to earnings", group="Risk", kind=MetricKind.COUNT, help="Trading sessions until the next earnings release; missing when none is scheduled.", low=0.0, high=300.0),
    Metric(name="screen_score", label="screen score", group="Risk", kind=MetricKind.SCORE, help="The quant screen's composite score, from 0 to 1; missing for held stocks and wildcards.", low=0.0, high=1.0),
    Metric(name="ticker", label="ticker", group="Stock", kind=MetricKind.CATEGORY, help="The stock's symbol, such as AAPL."),
    Metric(name="sector", label="sector", group="Stock", kind=MetricKind.CATEGORY, help="The stock's GICS sector.", choices=SECTORS),
    Metric(name="regime", label="Macro regime", group="Market", kind=MetricKind.CATEGORY, help="The Macro agent's call on the market: RISK_ON, NEUTRAL, or RISK_OFF.", choices=REGIMES),
    Metric(name="spy_vs_sma_200", label="SPY against its 200-day average", group="Market", kind=MetricKind.SHARE, help="How far SPY's close is above (+) or below (-) its 200-day average.", low=-1.0, high=5.0),
    Metric(name="return_since_entry", label="return since entry", group="Position", kind=MetricKind.SHARE, help="A held position's return from its average entry price to the last close.", low=-1.0, high=10.0, held_only=True),
    Metric(name="sessions_held", label="sessions held", group="Position", kind=MetricKind.COUNT, help="Trading sessions since the position opened.", low=0.0, high=2000.0, held_only=True)
];

glob METRIC_BY_NAME: dict[str, Metric] = {m.name: m for m in METRICS};
glob KNOB_BY_NAME: dict[str, Knob] = {k.name: k for k in KNOBS};
glob NUMBER_OPS: list[Op] = [Op.LT, Op.LE, Op.GT, Op.GE];
glob WORD_OPS: list[Op] = [Op.IN, Op.NOT_IN];
glob OP_WORDS: dict[Op, str] = {Op.LT: "is below", Op.LE: "is at most", Op.GT: "is above", Op.GE: "is at least", Op.IN: "is", Op.NOT_IN: "is not"};
glob EXIT_EFFECTS: list[RuleEffect] = [RuleEffect.SELL, RuleEffect.TRIM, RuleEffect.KEEP];

"""What one ticker's rules can test. Numbers and words are kept apart; a metric missing from
both is unknown."""
obj Facts {
    has numbers: dict[str, float] = {},
        words: dict[str, str] = {};

    def put(name: str, value: float | None) {
        if value is not None and math.isfinite(value) {
            self.numbers[name] = float(value);
        }
    }

    def put_word(name: str, value: str) {
        if value {
            self.words[name] = value;
        }
    }
}

"""One change the policy made to a ticker's action, with the rule that made it ("" for the
time stop) and why, in words."""
obj PolicyStep {
    has rule_id: str,
        before: TradeAction,
        after: TradeAction,
        detail: str;
}

"""How a policy settled one ticker: the base action from its thresholds, the action after its
rules, each change, and each rule it could not check."""
obj PolicyOutcome {
    has base: TradeAction,
        action: TradeAction;
    has steps: list[PolicyStep] = [],
        skipped: list[str] = [];

    def changed -> bool {
        return self.action != self.base;
    }

    """The steps and skipped rules as lines for a decision's record."""
    def notes -> list[str] {
        return [s.detail for s in self.steps] + self.skipped;
    }
}

# --- Applying a policy ------------------------------------------------------------------

"""The consensus engine's thresholds from `policy`, with the run's sampling settings."""
def consensus_config(policy: Policy, samples: int = 3, extra_samples: int = 2) -> ConsensusConfig {
    return ConsensusConfig(
        samples=samples,
        extra_samples=extra_samples,
        buy_score=policy.buy_score,
        buy_agreement=policy.buy_agreement,
        sell_score=policy.sell_score,
        trim_agreement=policy.trim_agreement
    );
}

def sizing_config(policy: Policy) -> SizingConfig {
    return SizingConfig(
        scale=policy.sizing_scale,
        max_position_weight=policy.max_position_weight,
        gross_exposure_limit=policy.gross_limit,
        trim_fraction=policy.trim_fraction
    );
}

def gate_config(policy: Policy) -> GateConfig {
    return GateConfig(
        max_position_weight=policy.max_position_weight,
        sector_cap=policy.sector_cap,
        gross_limit=policy.gross_limit,
        regime_gross_limit=policy.regime_gross_limit,
        new_positions_per_day=policy.new_positions_per_day,
        turnover_limit=policy.turnover_limit,
        drawdown_halt=policy.drawdown_halt,
        earnings_blackout_sessions=policy.earnings_blackout_sessions,
        stop_atr_multiple=policy.stop_atr_multiple
    );
}

"""Settle one ticker under `policy`. `panel` is its consensus, or None when it has none;
`forced` is true when the panel could not decide it, which makes it a HOLD that only exit
rules can change. `exit_due` is true when a held position's time stop has passed."""
def evaluate(policy: Policy, facts: Facts, held: bool, panel: Consensus | None, exit_due: bool = False, forced: bool = False) -> PolicyOutcome {
    timed_out = exit_due and held and policy.time_stop;
    forced = forced or panel is None;
    base: TradeAction = TradeAction.HOLD;
    if not forced and panel is not None {
        base = decide(panel.score, panel.agreement, panel.ci_low, held, timed_out, consensus_config(policy));
    }
    found = PolicyOutcome(base=base, action=base);
    if forced {
        _exits(policy, facts, held, found);
        return found;
    }
    if found.action in (TradeAction.BUY, TradeAction.ADD) {
        _entries(policy, facts, found);
    }
    if held and found.action in (TradeAction.SELL, TradeAction.TRIM) {
        _keeps(policy, facts, found, timed_out);
    }
    _exits(policy, facts, held, found);
    return found;
}

def _entries(policy: Policy, facts: Facts, found: PolicyOutcome) {
    blocked = TradeAction.HOLD if found.action == TradeAction.ADD else TradeAction.NO_ACTION;
    for rule in _active(policy, [RuleEffect.AVOID_BUY, RuleEffect.BUY_ONLY_IF]) {
        state = rule_state(rule, facts);
        if state is None {
            found.skipped.append(_skip_note(rule, facts));
            continue;
        }
        fires = state if rule.effect == RuleEffect.AVOID_BUY else not state;
        if fires {
            why = f"{_name(rule)} held" if rule.effect == RuleEffect.AVOID_BUY else f"{_name(rule)} did not hold";
            found.steps.append(PolicyStep(rule_id=rule.id, before=found.action, after=blocked, detail=f"{_verb(found.action)} became {_action_words(blocked)}: {why} ({facts_text(rule, facts)})."));
            found.action = blocked;
            return;
        }
    }
}

def _keeps(policy: Policy, facts: Facts, found: PolicyOutcome, timed_out: bool) {
    for rule in _active(policy, [RuleEffect.KEEP]) {
        state = rule_state(rule, facts);
        if state is None {
            found.skipped.append(_skip_note(rule, facts));
        } elif state {
            cause = "the time stop" if timed_out and found.action == TradeAction.SELL else "the thresholds";
            found.steps.append(PolicyStep(rule_id=rule.id, before=found.action, after=TradeAction.HOLD, detail=f"The {_action_words(found.action)} from {cause} became a hold: {_name(rule)} held ({facts_text(rule, facts)})."));
            found.action = TradeAction.HOLD;
            return;
        }
    }
}

def _exits(policy: Policy, facts: Facts, held: bool, found: PolicyOutcome) {
    if not held {
        return;
    }
    for effect in [RuleEffect.SELL, RuleEffect.TRIM] {
        for rule in _active(policy, [effect]) {
            if found.action == TradeAction.SELL or (effect == RuleEffect.TRIM and found.action == TradeAction.TRIM) {
                return;
            }
            state = rule_state(rule, facts);
            if state is None {
                found.skipped.append(_skip_note(rule, facts));
            } elif state {
                after = TradeAction.SELL if effect == RuleEffect.SELL else TradeAction.TRIM;
                found.steps.append(PolicyStep(rule_id=rule.id, before=found.action, after=after, detail=f"{_action_words(found.action).capitalize()} became {_action_words(after)}: {_name(rule)} held ({facts_text(rule, facts)})."));
                found.action = after;
            }
        }
    }
}

def _active(policy: Policy, effects: list[RuleEffect]) -> list[PolicyRule] {
    return [r for r in policy.rules if r.enabled and r.effect in effects];
}

"""True when every condition holds, False when one fails, and None when none fails but one
cannot be checked."""
def rule_state(rule: PolicyRule, facts: Facts) -> bool | None {
    unknown = False;
    for c in rule.conditions {
        state = condition_holds(c, facts);
        if state is None {
            unknown = True;
        } elif not state {
            return False;
        }
    }
    return None if unknown else True;
}

def condition_holds(c: Condition, facts: Facts) -> bool | None {
    if c.op in WORD_OPS {
        value = facts.words.get(c.metric);
        if value is None {
            return None;
        }
        inside = value.upper() in [w.upper() for w in c.words];
        return inside if c.op == Op.IN else not inside;
    }
    number = facts.numbers.get(c.metric);
    if number is None or c.number is None {
        return None;
    }
    limit = c.number;
    if c.op == Op.LT {
        return number < limit;
    }
    if c.op == Op.LE {
        return number <= limit;
    }
    if c.op == Op.GT {
        return number > limit;
    }
    return number >= limit;
}

def _skip_note(rule: PolicyRule, facts: Facts) -> str {
    missing = [metric_label(c.metric) for c in rule.conditions if condition_holds(c, facts) is None];
    return f"{_name(rule).capitalize()} was not checked: no {', '.join(_unique(missing))} for this stock.";
}

def _name(rule: PolicyRule) -> str {
    return f"rule {rule.id}" + (f" \"{rule.label}\"" if rule.label else "");
}

"""The rule's metrics as this ticker had them, for an explanation: "RSI(14) 74.2"."""
def facts_text(rule: PolicyRule, facts: Facts) -> str {
    parts: list[str] = [];
    for c in rule.conditions {
        m = METRIC_BY_NAME.get(c.metric);
        label = m.label if m is not None else c.metric;
        if c.metric in facts.words {
            parts.append(f"{label} {_word_text(c.metric, facts.words[c.metric])}");
        } elif c.metric in facts.numbers {
            parts.append(f"{label} {metric_value_text(c.metric, facts.numbers[c.metric])}");
        } else {
            parts.append(f"{label} unknown");
        }
    }
    return "; ".join(_unique(parts));
}

# --- Checking a policy ------------------------------------------------------------------

"""Every way `policy` breaks its limits, in words; empty when it is valid."""
def validate(policy: Policy) -> list[str] {
    problems: list[str] = [];
    for k in KNOBS {
        value = knob_value(policy, k.name);
        if not math.isfinite(value) {
            problems.append(f"{k.label} must be a number.");
        } elif value < k.low - 1e-9 or value > k.high + 1e-9 {
            problems.append(f"{k.label} must be between {knob_text(k, k.low)} and {knob_text(k, k.high)}; it is {knob_text(k, value)}.");
        } elif k.int_valued and value != round(value) {
            problems.append(f"{k.label} must be a whole number.");
        }
    }
    if policy.max_position_weight > policy.gross_limit {
        problems.append("Largest position cannot be more than the most invested.");
    }
    if policy.max_position_weight > policy.sector_cap {
        problems.append("Largest position cannot be more than the largest sector.");
    }
    if len(policy.rules) > MAX_RULES {
        problems.append(f"A policy can have at most {MAX_RULES} rules.");
    }
    seen: set[str] = set();
    for rule in policy.rules {
        if not rule.id.strip() {
            problems.append("Every rule needs an id.");
        } elif rule.id in seen {
            problems.append(f"Rule id {rule.id} is used twice.");
        }
        seen.add(rule.id);
        problems.extend(check_rule(rule));
    }
    return problems;
}

def check_rule(rule: PolicyRule) -> list[str] {
    name = f"Rule {rule.id}";
    problems: list[str] = [];
    if len(rule.label) > MAX_LABEL_CHARS {
        problems.append(f"{name}'s name must be at most {MAX_LABEL_CHARS} characters.");
    }
    if not rule.conditions {
        problems.append(f"{name} needs at least one condition.");
    }
    if len(rule.conditions) > MAX_CONDITIONS {
        problems.append(f"{name} can have at most {MAX_CONDITIONS} conditions.");
    }
    for c in rule.conditions {
        problems.extend(f"{name}: {p}" for p in check_condition(c));
    }
    return problems;
}

def check_condition(c: Condition) -> list[str] {
    m = METRIC_BY_NAME.get(c.metric);
    if m is None {
        return [f"{c.metric} is not a metric a rule can test."];
    }
    if m.kind == MetricKind.CATEGORY {
        if c.op not in WORD_OPS {
            return [f"{m.label} can only be compared with \"is\" or \"is not\"."];
        }
        if not c.words {
            return [f"{m.label} needs at least one value."];
        }
        if len(c.words) > MAX_WORDS {
            return [f"{m.label} can list at most {MAX_WORDS} values."];
        }
        if m.choices {
            wrong = [w for w in c.words if w not in m.choices];
            if wrong {
                return [f"{', '.join(wrong)} is not a {m.label}; use {', '.join(m.choices)}."];
            }
        } else {
            wrong = [w for w in c.words if not TICKER_PATTERN.match(w)];
            if wrong {
                return [f"{', '.join(wrong)} is not a ticker."];
            }
        }
        return [];
    }
    if c.op not in NUMBER_OPS {
        return [f"{m.label} must be compared with a number."];
    }
    if c.number is None or not math.isfinite(c.number) {
        return [f"{m.label} needs a number to compare with."];
    }
    if c.number < m.low or c.number > m.high {
        return [f"{m.label} is never {metric_value_text(m.name, c.number)}; use a value from {metric_value_text(m.name, m.low)} to {metric_value_text(m.name, m.high)}."];
    }
    return [];
}

"""`value` moved onto `knob`'s range and step, and made whole if it must be."""
def clamp_knob(knob: Knob, value: float) -> float {
    inside = min(knob.high, max(knob.low, value));
    stepped = round(inside / knob.step) * knob.step if knob.step > 0 else inside;
    stepped = min(knob.high, max(knob.low, round(stepped, 6)));
    return float(round(stepped)) if knob.int_valued else stepped;
}

def knob_value(policy: Policy, name: str) -> float {
    value = getattr(policy, name);
    return 1.0 if value is True else (0.0 if value is False else float(value));
}

"""A copy of `policy` with knob `name` set to `value`, converted to the knob's type."""
def with_knob(policy: Policy, name: str, value: float) -> Policy {
    found = copy_policy(policy);
    knob = KNOB_BY_NAME[name];
    if knob.unit == "switch" {
        setattr(found, name, value >= 0.5);
    } elif knob.int_valued {
        setattr(found, name, int(round(value)));
    } else {
        setattr(found, name, float(value));
    }
    return found;
}

def copy_policy(policy: Policy) -> Policy {
    found = Policy(rules=[copy_rule(r) for r in policy.rules]);
    for k in KNOBS {
        setattr(found, k.name, getattr(policy, k.name));
    }
    return found;
}

def copy_rule(rule: PolicyRule) -> PolicyRule {
    return PolicyRule(
        id=rule.id,
        effect=rule.effect,
        conditions=[Condition(metric=c.metric, op=c.op, number=c.number, words=list(c.words)) for c in rule.conditions],
        label=rule.label,
        enabled=rule.enabled
    );
}

"""The next free rule id: R1, R2, and so on, never reusing a number still in the policy."""
def next_rule_id(policy: Policy) -> str {
    used = [int(r.id[1:]) for r in policy.rules if r.id.startswith("R") and r.id[1:].isdigit()];
    return f"R{max(used, `default=0) + 1}";
}

# --- Saying it in words -----------------------------------------------------------------

def knob_text(knob: Knob, value: float) -> str {
    if knob.unit == "switch" {
        return "on" if value >= 0.5 else "off";
    }
    if knob.unit == "score" {
        return f"{value:+.2f}";
    }
    if knob.unit == "share" {
        return _percent(value);
    }
    if knob.unit == "multiple" {
        return f"{value:g}× ATR";
    }
    if knob.unit == "sessions" {
        return f"{int(round(value))} session" + ("" if int(round(value)) == 1 else "s");
    }
    return str(int(round(value)));
}

def metric_label(name: str) -> str {
    m = METRIC_BY_NAME.get(name);
    return m.label if m is not None else name;
}

def metric_value_text(name: str, value: float) -> str {
    m = METRIC_BY_NAME.get(name);
    if m is None {
        return f"{value:g}";
    }
    if m.kind == MetricKind.SCORE {
        return f"{value:+.2f}";
    }
    if m.kind == MetricKind.SHARE {
        return _percent(value, signed=m.low < 0);
    }
    if m.kind == MetricKind.COUNT {
        return str(int(round(value)));
    }
    return f"{value:.1f}".rstrip("0").rstrip(".");
}

def _word_text(name: str, word: str) -> str {
    return word.replace("_", " ").lower() if name == "regime" else word;
}

def _percent(value: float, signed: bool = False) -> str {
    text = f"{value * 100:.1f}".rstrip("0").rstrip(".");
    if signed and value > 0 {
        text = "+" + text;
    }
    return text + "%";
}

def condition_text(c: Condition) -> str {
    label = metric_label(c.metric);
    if c.op in WORD_OPS {
        words = [_word_text(c.metric, w) for w in c.words];
        if len(words) <= 1 {
            return f"{label} {OP_WORDS[c.op]} {words[0] if words else 'nothing'}";
        }
        verb = "is one of" if c.op == Op.IN else "is none of";
        return f"{label} {verb} {', '.join(words)}";
    }
    number = metric_value_text(c.metric, c.number) if c.number is not None else "?";
    return f"{label} {OP_WORDS.get(c.op, str(c.op.value))} {number}";
}

glob EFFECT_LEADS: dict[RuleEffect, str] = {
    RuleEffect.AVOID_BUY: "Don't buy or add when",
    RuleEffect.BUY_ONLY_IF: "Buy or add only when",
    RuleEffect.SELL: "Sell a held stock when",
    RuleEffect.TRIM: "Trim a held stock when",
    RuleEffect.KEEP: "Keep a held stock instead of selling or trimming it when"
};

"""A rule as one sentence: "Don't buy or add when RSI(14) is above 70."."""
def rule_sentence(rule: PolicyRule) -> str {
    conditions = " and ".join(condition_text(c) for c in rule.conditions) or "never";
    return f"{EFFECT_LEADS[rule.effect]} {conditions}.";
}

"""What `policy` does, as short sentences: the decision rule first, then the rules, then the
limits that differ from the defaults."""
def describe(policy: Policy) -> list[str] {
    lines = [
        f"Buy or add when the panel score is at least {policy.buy_score:+.2f}, at least {_percent(policy.buy_agreement)} of samples agree, and the score's interval stays above zero.",
        f"Sell a held stock when the panel score falls to {policy.sell_score:+.2f} or below" + (", or when its time stop passes." if policy.time_stop else "; time stops are off."),
        f"Otherwise hold, trimming {_percent(policy.trim_fraction)} of a position when agreement falls below {_percent(policy.trim_agreement)}."
    ];
    for rule in policy.rules {
        lines.append(("Paused: " if not rule.enabled else "") + rule_sentence(rule));
    }
    defaults = Policy();
    limits = [k for k in KNOBS if k.group in ("Sizing", "Limits") and knob_value(policy, k.name) != knob_value(defaults, k.name)];
    if limits {
        lines.append("Limits: " + "; ".join(f"{k.label.lower()} {knob_text(k, knob_value(policy, k.name))}" for k in limits) + ".");
    } else {
        lines.append("Sizing and risk limits are the defaults.");
    }
    return lines;
}

"""What changed from `before` to `after`, one line per change; empty when nothing did."""
def changes(before: Policy, after: Policy) -> list[str] {
    lines: list[str] = [];
    for k in KNOBS {
        (a, b) = (knob_value(before, k.name), knob_value(after, k.name));
        if not math.isclose(a, b, abs_tol=1e-9) {
            lines.append(f"{k.label}: {knob_text(k, a)} → {knob_text(k, b)}");
        }
    }
    old = {r.id: r for r in before.rules};
    new = {r.id: r for r in after.rules};
    for r in after.rules {
        if r.id not in old {
            lines.append(f"Added rule {r.id}: {rule_sentence(r)}");
        } elif rule_sentence(r) != rule_sentence(old[r.id]) or r.label != old[r.id].label {
            lines.append(f"Changed rule {r.id}: {rule_sentence(r)}");
        } elif r.enabled != old[r.id].enabled {
            lines.append(f"{'Resumed' if r.enabled else 'Paused'} rule {r.id}: {rule_sentence(r)}");
        }
    }
    for r in before.rules {
        if r.id not in new {
            lines.append(f"Removed rule {r.id}: {rule_sentence(r)}");
        }
    }
    return lines;
}

glob ACTION_WORDS: dict[TradeAction, str] = {
    TradeAction.BUY: "buy",
    TradeAction.ADD: "add",
    TradeAction.HOLD: "hold",
    TradeAction.TRIM: "trim",
    TradeAction.SELL: "sell",
    TradeAction.NO_ACTION: "no action"
};

def _action_words(action: TradeAction) -> str {
    return ACTION_WORDS[action];
}

def _verb(action: TradeAction) -> str {
    return "The " + _action_words(action);
}

def _unique(items: list[str]) -> list[str] {
    seen: list[str] = [];
    for item in items {
        if item not in seen {
            seen.append(item);
        }
    }
    return seen;
}

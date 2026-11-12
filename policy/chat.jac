"""The policy chat (TDD §9, policies): a message goes to the assistant in the background, and
its answer is stored the next time the client asks, on that user's own root.

A request holds a serializable transaction, so a model call, which can take a minute, never
runs inside one (reports/api.jac keeps the same rule). `send_policy_message` stores the message
and, once that has committed, starts the call on a pool thread, so a transaction that fails
leaves no model call behind. The thread cannot touch the graph, so everything it needs is read
first and passed as text. `get_policy_chat`, which the client calls until nothing is pending,
turns a finished call into an assistant turn, and keeps the call's result until that commits.

The model only drafts. Code applies its edits to a copy and checks them against the form's
limits, and the proposal changes nothing until its owner applies it. The same save path as the
form then refuses it if the policy moved in the meantime. A message uses its sender's own
OpenRouter key, with a daily limit so a long chat cannot eat their morning run's allowance. The
admin's agent uses the server's key, and that allowance also holds back the morning run's share.
"""
import logging;
import os;
import re;
import time;
import from concurrent.futures { Future }
import from datetime { datetime, timedelta, timezone }
import from accounts.store { caller_is_admin, credentials_of, demo_mode, my_account, my_portfolio }
import from accounts.vault { VaultError }
import from agents.models { FREE_REQUESTS_PER_DAY, REQUEST_BUDGET, RequestBudget, limiter_now, models_disabled }
import from agents.policy_assistant { PolicyAnswer, answer_policy_message }
import from analysis.policy { KNOBS, MAX_LABEL_CHARS, METRICS, METRIC_BY_NAME, changes as changes_between, copy_policy, knob_text, knob_value, next_rule_id, rule_sentence, validate, with_knob }
import from models.graph { Ran, Run, RunStatus }
import from models.policy { ChatTurn, Condition, ConditionDraft, EditKind, MetricKind, Op, Policy, PolicyEdit, PolicyRule, PolicyScope, RuleEffect }
import from models.policy_views { ChatActionReply, ChatState, ChatTurnView, ReplayRow, ReplayView }
import from policy.api { policy_doc }
import from policy.replay { StoredRun, replay, replay_my_run, latest_run_of_mine }
import from policy.store { current_of, my_scope, save_policy, versions_of }
import from research.credentials { Credentials, OPENROUTER_KEY, enter_credentials, leave_credentials }
import from run.agents { is_running }
import from research.collector { parse_utc, utc_now }
import from run.guard { NEW_YORK, stored_requests }
import from run.workers { ContextPool }

glob LOG: logging.Logger = logging.getLogger("trading_agent.policy");
glob MAX_MESSAGE_CHARS: int = 500;
glob MAX_TURNS_SHOWN: int = 40;
glob MAX_TURNS_IN_PROMPT: int = 6;
glob MAX_IMPACT_LINES: int = 6;
glob DEFAULT_DAILY_LIMIT: int = 20;
# One message may use a parse retry and a fallback or two, and no more.
glob REQUESTS_PER_MESSAGE: int = 4;
glob ANSWER_DEADLINE_S: float = 150.0;
# After this long a pending message's answer is taken as lost.
glob PENDING_LIMIT_S: float = 300.0;
# A message's call starts just after its commit, so another request can see the message first.
# A message with no call for this long was left by a restart.
glob START_GRACE_S: float = 30.0;
# What must stay in the day's allowance: a morning run's share until it has finished, and the
# reports' floor (reports/api.jac) after that. Reports hold back the same 150.
glob RESERVE_BEFORE_RUN: int = 650;
glob RESERVE_AFTER_RUN: int = 150;
glob POOL: ContextPool = ContextPool(max_workers=4, thread_name_prefix="policy-chat");
glob ANSWERS: dict[str, Future[AssistantResult]] = {};
glob TICKER_WORD: re.Pattern[str] = re.compile(r"\b[A-Za-z]{1,5}(?:[.-][A-Za-z])?\b");

"""What a finished assistant call gives back to the request that collects it."""
obj AssistantResult {
    has answer: PolicyAnswer | None = None,
        error: str = "",
        requests: int = 0;
}

"""What the assistant is told, read from the graph before its pool thread starts."""
obj Brief {
    has message: str,
        policy_scope: str,
        current_rules: str,
        settings: str,
        metrics: str,
        latest_run: str,
        conversation: str;
}

def daily_limit -> int {
    try {
        return max(0, int(os.environ.get("POLICY_CHAT_PER_USER_DAY", str(DEFAULT_DAILY_LIMIT))));
    } except ValueError {
        return 0;
    }
}

"""The sender's keys for a call, or None for the server's own: the admin's agent, and a demo
server, which shows every user the same made-up history."""
def keys_for_chat -> Credentials | None {
    if caller_is_admin() or demo_mode() {
        return None;
    }
    account = my_account();
    return credentials_of(account) if account is not None else Credentials({});
}

"""Why a message on the server's own key cannot be sent, or "" when it can."""
def server_chat_refusal(now: datetime) -> str {
    if not os.environ.get(OPENROUTER_KEY, "") {
        return "The assistant is off on this server. You can still edit the policy here.";
    }
    portfolio = my_portfolio();
    utc_day = now.astimezone(timezone.utc).date().isoformat();
    used = limiter_now().sent_by_day.get(utc_day, 0);
    reserve = RESERVE_BEFORE_RUN;
    if portfolio is not None {
        used = max(used, stored_requests(portfolio, utc_day));
        day = now.astimezone(NEW_YORK).date().isoformat();
        runs = [r for r in [portfolio ->:Ran:->[?:Run]]];
        if any(r.status == RunStatus.RUNNING for r in runs) {
            return "The morning run is using the models, so the assistant is paused until it finishes.";
        }
        if any(r.run_date == day and r.finished_at for r in runs) {
            reserve = RESERVE_AFTER_RUN;
        }
    }
    if FREE_REQUESTS_PER_DAY - used < reserve {
        return "The day's model requests are held back for the morning run and reports. The assistant returns tomorrow.";
    }
    return "";
}

"""Why no new message can be sent right now, or "" when one can."""
def unavailable_reason(now: datetime) -> str {
    if models_disabled() {
        return "The assistant is off on this server. You can still edit the policy here.";
    }
    try {
        keys = keys_for_chat();
    } except VaultError {
        return "Connect your OpenRouter key again in Settings to use the assistant.";
    }
    if keys is None {
        return server_chat_refusal(now);
    }
    if OPENROUTER_KEY not in keys.keys {
        return "Connect your OpenRouter key in Settings to use the assistant. You can still edit the policy here.";
    }
    if is_running(keys.owner) {
        return "Your morning run is using your model allowance, so the assistant is paused until it finishes.";
    }
    return "";
}

"""The caller's own turns about `scope`, oldest first."""
def turns_of(scope: PolicyScope) -> list[ChatTurn] {
    found = [t for t in [root -->[?:ChatTurn]] if t.scope == scope];
    return sorted(found, key=lambda (t: ChatTurn) { t.at; });
}

"""Messages the caller has used today, across both policies."""
def used_today(now: datetime) -> int {
    day = now.astimezone(timezone.utc).date().isoformat();
    return len([t for t in [root -->[?:ChatTurn]] if t.role == "user" and t.at[:10] == day and t.status != "failed"]);
}

# --- Applying a proposal ------------------------------------------------------------------

"""`words` as the metric stores them: tickers in capitals, a category's own spelling."""
def normal_words(metric: str, words: list[str]) -> list[str] {
    known = METRIC_BY_NAME.get(metric);
    if known is None or known.kind != MetricKind.CATEGORY {
        return words;
    }
    if not known.choices {
        return [w.strip().upper().replace(".", "-") for w in words];
    }
    spelled = {c.lower(): c for c in known.choices};
    return [spelled.get(w.strip().lower(), w) for w in words];
}

def condition_from(c: ConditionDraft) -> Condition {
    if c.op in (Op.IN, Op.NOT_IN) {
        return Condition(metric=c.metric, op=c.op, words=normal_words(c.metric, c.words));
    }
    return Condition(metric=c.metric, op=c.op, number=c.number);
}

"""`edits` applied to a copy of `policy`, and why the result cannot be applied (the same limits
as the form, so the model cannot propose past them)."""
def apply_edits(policy: Policy, edits: list[PolicyEdit]) -> tuple[Policy, list[str]] {
    found = copy_policy(policy);
    problems: list[str] = [];
    for edit in edits {
        if edit.kind == EditKind.SET {
            found = with_knob(found, edit.setting, edit.value if edit.value is not None else 0.0);
        } elif edit.kind == EditKind.ADD_RULE {
            if edit.effect is None {
                problems.append("A new rule needs an effect.");
                continue;
            }
            found.rules.append(PolicyRule(id=next_rule_id(found), effect=edit.effect, conditions=[condition_from(c) for c in edit.conditions], label=edit.label.strip()[:MAX_LABEL_CHARS]));
        } else {
            matching = [r for r in found.rules if r.id == edit.rule_id.strip()];
            if not matching {
                problems.append(f"There is no rule {edit.rule_id}.");
            } elif edit.kind == EditKind.REMOVE_RULE {
                found.rules = [r for r in found.rules if r.id != edit.rule_id.strip()];
            } else {
                matching[0].enabled = edit.kind == EditKind.RESUME_RULE;
            }
        }
    }
    return (found, problems + validate(found));
}

"""What `proposal` would change in the team's latest run, compared with `current`."""
def impact_of(current: Policy, proposal: Policy) -> list[str] {
    before = replay_my_run(current);
    after = replay_my_run(proposal);
    if not before.rows or not after.rows {
        return [];
    }
    was = {r.ticker: r.action for r in before.rows};
    moved = [r for r in after.rows if was.get(r.ticker, r.action) != r.action];
    if not moved {
        return [f"No decision in the {after.run_date} run would change."];
    }
    lines = [f"{r.ticker}: {was[r.ticker]} would become {r.action}" for r in moved[:MAX_IMPACT_LINES]];
    if len(moved) > MAX_IMPACT_LINES {
        lines.append(f"and {len(moved) - MAX_IMPACT_LINES} more");
    }
    return [f"In the {after.run_date} run:"] + lines;
}

# --- What the assistant is told -----------------------------------------------------------

def settings_text(policy: Policy) -> str {
    lines = [f"{k.name} = {knob_text(k, knob_value(policy, k.name))} (limits {knob_text(k, k.low)} to {knob_text(k, k.high)}): {k.label}. {k.help}" for k in KNOBS];
    return "\n".join(lines);
}

def metrics_text -> str {
    lines: list[str] = [];
    for m in METRICS {
        values = (", ".join(m.choices) if m.choices else "any ticker") if m.kind == MetricKind.CATEGORY else f"{m.low:g} to {m.high:g}";
        held = " Only for held stocks." if m.held_only else "";
        lines.append(f"{m.name} ({m.kind.value}; {values}): {m.label}. {m.help}{held}");
    }
    return "\n".join(lines);
}

def rules_text(policy: Policy) -> str {
    if not policy.rules {
        return "No rules yet.";
    }
    return "\n".join(f"{r.id}{'' if r.enabled else ' (paused)'}: {rule_sentence(r)}" for r in policy.rules);
}

"""The tickers `message` names, among those `run` covered."""
def mentioned(message: str, run: StoredRun | None) -> set[str] {
    covered = {t.ticker for t in run.tickers} if run is not None else set();
    return {w.upper().replace(".", "-") for w in TICKER_WORD.findall(message)} & covered;
}

"""One line per covered stock: what the team decided and what `view` says this policy would, with
every stored figure for the stocks the message names."""
def run_text(view: ReplayView, run: StoredRun | None, named: set[str]) -> str {
    if not view.rows or run is None {
        return "No morning run has decided anything yet.";
    }
    facts = {t.ticker: t.facts for t in run.tickers};
    lines = [f"Run of {view.run_date}, {len(view.rows)} stocks covered."];
    for r in sorted(view.rows, key=lambda (row: ReplayRow) { row.ticker; }) {
        score = f"score {r.score:.2f}, agreement {r.agreement:.2f}" if r.score is not None and r.agreement is not None else "no panel score";
        line = f"{r.ticker} ({r.sector}{', held' if r.held else ''}): {score}; team {r.run_action}; this policy {r.action}.";
        if r.notes {
            line += " " + " ".join(r.notes);
        }
        if r.skipped {
            line += " Not checked: " + " ".join(r.skipped);
        }
        if r.ticker in named {
            found = facts[r.ticker];
            line += " Figures: " + ", ".join([f"{k} {v:g}" for (k, v) in sorted(found.numbers.items())] + [f"{k} {v}" for (k, v) in sorted(found.words.items())]) + ".";
        }
        lines.append(line);
    }
    return "\n".join(lines);
}

def brief_for(policy: Policy, message: str, earlier: list[ChatTurn]) -> Brief {
    run = latest_run_of_mine();
    whose = "The user's own policy: changing it changes their agent's morning runs from the next one on.";
    conversation = "\n".join(f"{t.role}: {t.text}" for t in earlier[-MAX_TURNS_IN_PROMPT:]) or "None yet.";
    view = replay(policy, run) if run is not None else ReplayView();
    return Brief(message=message, policy_scope=whose, current_rules=rules_text(policy), settings=settings_text(policy), metrics=metrics_text(), latest_run=run_text(view, run, mentioned(message, run)), conversation=conversation);
}

"""Ask the assistant, on a pool thread and on `keys` (the server's own when None): no graph here."""
def ask(brief: Brief, keys: Credentials | None = None) -> AssistantResult {
    budget = RequestBudget(remaining=REQUESTS_PER_MESSAGE, deadline=time.monotonic() + ANSWER_DEADLINE_S);
    token = REQUEST_BUDGET.set(budget);
    scope = enter_credentials(keys) if keys is not None else None;
    try {
        answer = answer_policy_message(brief.message, brief.policy_scope, brief.current_rules, brief.settings, brief.metrics, brief.latest_run, brief.conversation);
        return AssistantResult(answer=answer, requests=budget.used);
    } except Exception as e {
        LOG.warning("policy assistant failed: %s", str(e)[:500]);
        return AssistantResult(error=type(e).__name__, requests=budget.used);
    } finally {
        if scope is not None {
            leave_credentials(scope);
        }
        REQUEST_BUDGET.reset(token);
    }
}

# --- The chat as stored -------------------------------------------------------------------

"""Turn a finished answer for `user_turn` into an assistant turn."""
def store_answer(user_turn: ChatTurn, result: AssistantResult) {
    now = utc_now().isoformat();
    answer = result.answer;
    if answer is None {
        user_turn.status = "failed";
        root ++> ChatTurn(scope=user_turn.scope, role="assistant", text="I could not get an answer from the model just now, so nothing changed. Please try again, or edit the policy directly.", at=now, status="error", requests=result.requests);
        return;
    }
    user_turn.status = "answered";
    made = ChatTurn(scope=user_turn.scope, role="assistant", text=answer.reply.strip(), at=now, question=user_turn.text, requests=result.requests);
    if answer.edits {
        (current, version) = current_of(versions_of(user_turn.scope));
        (proposal, problems) = apply_edits(current, answer.edits);
        made.base_version = version;
        made.problems = problems;
        if problems {
            made.status = "invalid";
        } else {
            made.proposal = proposal;
            made.changes = changes_between(current, proposal);
            made.impact = impact_of(current, proposal);
            made.status = "proposed" if made.changes else "invalid";
            if not made.changes {
                made.problems = ["That would not change anything in the policy."];
            }
        }
    }
    root ++> made;
}

def forget(key: str) -> Callable[[], object] {
    return lambda { ANSWERS.pop(key, None); };
}

def start_answer(key: str, brief: Brief, keys: Credentials | None) -> Callable[[], object] {
    return lambda { ANSWERS[key] = POOL.submit(ask, brief, keys); };
}

"""Collect any finished answers among `turns`, in this request's transaction."""
def collect_answers(turns: list[ChatTurn], now: datetime) -> bool {
    pending = False;
    for t in turns {
        if t.role != "user" or t.status != "pending" {
            continue;
        }
        key = jid(t);
        future = ANSWERS.get(key);
        age = now - parse_utc(t.at);
        if future is None and age < timedelta(seconds=START_GRACE_S) {
            pending = True;
        } elif future is None or (not future.done() and age > timedelta(seconds=PENDING_LIMIT_S)) {
            on_commit(forget(key));
            store_answer(t, AssistantResult(error="lost"));
        } elif future.done() {
            # Keep the future until commit; a failed transaction must not lose its result.
            on_commit(forget(key));
            store_answer(t, future.result());
        } else {
            pending = True;
        }
    }
    return pending;
}

def turn_view(t: ChatTurn, current_version: int) -> ChatTurnView {
    status = "stale" if t.status == "proposed" and t.base_version != current_version else t.status;
    return ChatTurnView(id=jid(t), role=t.role, text=t.text, at=t.at, changes=t.changes, problems=t.problems, impact=t.impact, status=status, applied_version=t.applied_version);
}

def chat_state(scope: PolicyScope, now: datetime) -> ChatState {
    pending = collect_answers(turns_of(scope), now);
    version = current_of(versions_of(scope))[1];
    limit = daily_limit();
    left = max(0, limit - used_today(now));
    reason = unavailable_reason(now);
    if not reason and left == 0 {
        reason = f"You have used today's {limit} messages. You can still edit the policy here.";
    }
    return ChatState(scope=scope.value, turns=[turn_view(t, version) for t in turns_of(scope)[-MAX_TURNS_SHOWN:]], pending=pending, available=not reason, note=reason, remaining=left, daily_limit=limit);
}

def own_turn(turn_id: str) -> ChatTurn | None {
    for t in [root -->[?:ChatTurn]] {
        if jid(t) == turn_id and t.role == "assistant" {
            return t;
        }
    }
    return None;
}

# --- Endpoints ----------------------------------------------------------------------------

"""The caller's chat about their policy, collecting any answer that has finished."""
def:protect get_policy_chat -> ChatState {
    return chat_state(my_scope(), utc_now());
}

"""Send `text` to the assistant. It answers in the background; `get_policy_chat` collects it."""
def:protect send_policy_message(text: str) -> ChatState {
    target = my_scope();
    now = utc_now();
    state = chat_state(target, now);
    message = " ".join(text.split());
    if state.pending or not state.available or not message {
        return state;
    }
    if len(message) > MAX_MESSAGE_CHARS {
        state.note = f"Please keep a message under {MAX_MESSAGE_CHARS} characters.";
        return state;
    }
    earlier = [t for t in turns_of(target) if t.status != "error"];
    (policy, _) = current_of(versions_of(target));
    turn = root ++> ChatTurn(scope=target, role="user", text=message, at=now.isoformat(), status="pending");
    on_commit(start_answer(jid(turn), brief_for(policy, message, earlier), keys_for_chat()));
    return chat_state(target, now);
}

"""Apply proposal `turn_id`: only the caller's own, and only if the policy has not moved since it
was drafted."""
def:protect apply_policy_proposal(turn_id: str) -> ChatActionReply {
    now = utc_now();
    turn = own_turn(turn_id);
    if turn is None {
        return ChatActionReply(ok=False, message="That proposal is not on record.", chat=ChatState(scope=""));
    }
    scope = turn.scope;
    proposal = turn.proposal;
    if turn.status != "proposed" or proposal is None {
        return ChatActionReply(ok=False, message="That proposal is no longer open.", chat=chat_state(scope, now));
    }
    done = save_policy(scope, proposal, turn.base_version, "chat", turn.question);
    if done.saved {
        turn.status = "applied";
        turn.applied_version = done.version;
    } else {
        turn.status = "stale" if "changed since" in done.message else "invalid";
        turn.problems = done.problems or [done.message];
    }
    return ChatActionReply(ok=done.saved, message=done.message, chat=chat_state(scope, now), doc=policy_doc(scope, versions_of(scope)));
}

"""Set aside proposal `turn_id`; the policy stays as it is."""
def:protect discard_policy_proposal(turn_id: str) -> ChatActionReply {
    turn = own_turn(turn_id);
    if turn is None {
        return ChatActionReply(ok=False, message="That proposal is not on record.", chat=ChatState(scope=""));
    }
    if turn.status == "proposed" {
        turn.status = "discarded";
    }
    return ChatActionReply(ok=True, message="Discarded. Nothing changed.", chat=chat_state(turn.scope, utc_now()));
}

"""The policy endpoints (TDD §9, policies): each signed-in user reads and saves the one policy that
drives their agent, and tries any draft against its stored runs. A save changes the next morning
run and never a run already decided.

Replays read stored runs, so these endpoints spend no model request and place no order. Saving
checks a policy against its hard limits (analysis/policy.jac) whoever sends it, so the client
is never trusted with them.
"""
import from analysis.policy { EFFECT_LEADS, KNOBS, KNOB_GROUPS, MAX_CONDITIONS, MAX_RULES, METRICS, describe, rule_sentence }
import from models.policy { Op, Policy, PolicyScope, PolicyVersion, RuleEffect }
import from models.policy_views { EffectView, OpView, PolicyCatalog, PolicyDoc, PolicySaveReply, ReplayView, VersionView }
import from policy.replay { replay_my_run }
import from policy.store { current_of, my_scope, save_policy, versions_of }

glob OP_LABELS: dict[Op, str] = {Op.LT: "is below", Op.LE: "is at most", Op.GT: "is above", Op.GE: "is at least", Op.IN: "is one of", Op.NOT_IN: "is none of"};
glob MAX_HISTORY: int = 50;

"""A saved version as a reader sees it."""
def version_view(v: PolicyVersion) -> VersionView {
    return VersionView(version=v.version, saved_at=v.saved_at, author=v.author, source=v.source, note=v.note, changes=v.changes);
}

"""A policy in force among `versions`, with its words and its history, newest first."""
def policy_doc(scope: PolicyScope, versions: list[PolicyVersion]) -> PolicyDoc {
    (policy, number) = current_of(versions);
    return PolicyDoc(
        scope=scope.value,
        version=number,
        policy=policy,
        saved_at=versions[-1].saved_at if versions else "",
        sentences=describe(policy),
        rule_sentences=[rule_sentence(r) for r in policy.rules],
        history=[version_view(v) for v in reversed(versions[-MAX_HISTORY:])]
    );
}

def save_reply(scope: PolicyScope, policy: Policy, base_version: int, source: str, note: str) -> PolicySaveReply {
    done = save_policy(scope, policy, base_version, source, note);
    return PolicySaveReply(saved=done.saved, version=done.version, message=done.message, problems=done.problems, changes=done.changes, doc=policy_doc(scope, versions_of(scope)));
}

"""The ranges, metrics, and words an editor is built from."""
def:priv get_policy_catalog -> PolicyCatalog {
    return PolicyCatalog(
        knobs=KNOBS,
        groups=KNOB_GROUPS,
        metrics=METRICS,
        effects=[EffectView(value=e.value, lead=EFFECT_LEADS[e]) for e in list(RuleEffect)],
        ops=[OpView(value=o.value, label=OP_LABELS[o], words=o in (Op.IN, Op.NOT_IN)) for o in list(Op)],
        defaults=Policy(),
        max_rules=MAX_RULES,
        max_conditions=MAX_CONDITIONS
    );
}

"""What `policy` would have done with the caller's agent's run on `run_date` (the newest when
empty). Saves nothing, so a draft can be tried as it is edited."""
def:priv preview_policy(policy: Policy, run_date: str = "") -> ReplayView {
    return replay_my_run(policy, run_date);
}

"""The policy that drives the caller's agent."""
def:priv get_my_policy -> PolicyDoc {
    scope = my_scope();
    return policy_doc(scope, versions_of(scope));
}

"""Save `policy` as its next version, edited from `base_version`."""
def:priv save_policy_version(policy: Policy, base_version: int, note: str = "") -> PolicySaveReply {
    return save_reply(my_scope(), policy, base_version, "form", note);
}

"""Make version `version` the policy in force again, as a new version, so nothing in its history
is lost."""
def:priv restore_policy_version(version: int, base_version: int) -> PolicySaveReply {
    target = my_scope();
    versions = versions_of(target);
    for v in versions {
        if v.version == version {
            return save_reply(target, v.policy, base_version, "restore", f"Restored version {version}.");
        }
    }
    if version == 0 {
        return save_reply(target, Policy(), base_version, "restore", "Restored the defaults.");
    }
    return PolicySaveReply(saved=False, version=current_of(versions)[1], message=f"Version {version} is not on record.");
}

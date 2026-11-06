"""Saved policies: versions append and never change, a stale or invalid save is refused, and
team and personal policies stay apart."""
import from analysis.policy { with_knob }
import from models.policy { Condition, Op, Policy, PolicyRule, PolicyScope, PolicyVersion, RuleEffect }
import from policy.store { current_of, personal_versions, save_policy, team_policy, team_policy_version, team_versions }

def stop_rule -> PolicyRule {
    return PolicyRule(id="R1", effect=RuleEffect.SELL, conditions=[Condition(metric="return_since_entry", op=Op.LT, number=-0.08)]);
}

test "a personal policy starts as the defaults, and each save adds a version" {
    (start, base) = current_of(personal_versions());
    assert base == len(personal_versions());
    first = save_policy(PolicyScope.PERSONAL, with_knob(start, "buy_score", 0.45), base, "form", "  Stricter   buys ");
    assert first.saved and first.version == base + 1;
    assert any(c.startswith("Minimum panel score to buy:") for c in first.changes);
    stored = personal_versions()[-1];
    assert (stored.version, stored.source, stored.note, stored.author) == (base + 1, "form", "Stricter buys", "");
    second = save_policy(PolicyScope.PERSONAL, Policy(buy_score=0.45, rules=[stop_rule()]), first.version, "chat");
    assert second.saved and second.version == base + 2 and any(c.startswith("Added rule R1") for c in second.changes);
    # The older version is untouched.
    versions = personal_versions();
    assert versions[-2].policy.rules == [] and len(versions[-1].policy.rules) == 1;
    assert current_of(versions)[1] == base + 2;
}

test "a stale save, an invalid policy, and a save that changes nothing are refused" {
    (start, base) = current_of(personal_versions());
    moved = with_knob(start, "buy_score", 0.55 if start.buy_score != 0.55 else 0.6);
    done = save_policy(PolicyScope.PERSONAL, moved, base);
    assert done.saved;
    stale = save_policy(PolicyScope.PERSONAL, with_knob(moved, "buy_agreement", 0.9), base);
    assert not stale.saved and stale.version == done.version and "changed since" in stale.message;
    bad = save_policy(PolicyScope.PERSONAL, with_knob(moved, "max_position_weight", 0.5), done.version);
    assert not bad.saved and bad.problems and "Largest position" in bad.problems[0];
    same = save_policy(PolicyScope.PERSONAL, moved, done.version);
    assert not same.saved and same.message == "Nothing changed.";
    assert current_of(personal_versions())[1] == done.version;
}

test "a saved policy keeps its own copy" {
    (start, base) = current_of(personal_versions());
    draft = Policy(buy_score=0.65, rules=[stop_rule()]);
    assert save_policy(PolicyScope.PERSONAL, draft, base).saved;
    draft.buy_score = 0.9;
    draft.rules[0].enabled = False;
    kept = personal_versions()[-1].policy;
    assert kept.buy_score == 0.65 and kept.rules[0].enabled;
    assert start is not kept;
}

test "team versions live on root.shared, and an old or missing version is still readable" {
    (start, base) = team_policy();
    assert team_policy_version(0).buy_score == Policy().buy_score;
    done = save_policy(PolicyScope.TEAM, with_knob(start, "new_positions_per_day", 1.0 if start.new_positions_per_day != 1 else 2.0), base, "form", "Fewer entries");
    assert done.saved;
    stored = team_versions()[-1];
    assert stored.author == "Team admin" and stored.scope == PolicyScope.TEAM;
    assert team_policy()[1] == done.version and team_policy()[0].new_positions_per_day == stored.policy.new_positions_per_day;
    assert team_policy_version(done.version).new_positions_per_day == stored.policy.new_positions_per_day;
    assert team_policy_version(done.version + 50).new_positions_per_day == Policy().new_positions_per_day;
    # A team save is not a personal version.
    assert all(v.scope == PolicyScope.PERSONAL for v in personal_versions());
}

test "no versions mean the defaults, and a stored policy past its limits gives way to them" {
    (found, number) = current_of([]);
    assert number == 0 and found.buy_score == Policy().buy_score;
    past = PolicyVersion(scope=PolicyScope.PERSONAL, version=7, policy=Policy(max_position_weight=0.9), saved_at="2026-11-05T00:00:00+00:00");
    root ++> past;
    (kept, kept_number) = current_of([past]);
    assert kept_number == 7 and kept.max_position_weight == Policy().max_position_weight;
}

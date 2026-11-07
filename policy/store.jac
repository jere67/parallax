"""Where policies are kept (models/policy.jac): every saved version is a new PolicyVersion
node, the team's on root.shared and granted READ, a user's on their own root and private.

Nothing is edited in place, which suits the graph's permissions as well as the audit trail: a
request can attach a new node to root.shared but cannot change a node another root owns, so
an admin's save adds a version and the morning job reads the newest one. A save names the
version it was edited from, and is refused when a newer one exists, so two editors never
overwrite each other unseen.
"""
import logging;
import from analysis.policy { changes, copy_policy, validate }
import from models.policy { Policy, PolicyScope, PolicyVersion }
import from research.collector { utc_now }
import from research.credentials { current_credentials }
import from run.public { public }

glob LOG: logging.Logger = logging.getLogger("trading_agent.policy");
glob MAX_NOTE_CHARS: int = 300;
glob TEAM_AUTHOR: str = "Team admin";

"""What a save did: the version now in force, and why nothing was saved when it was not."""
obj SaveResult {
    has saved: bool,
        version: int;
    has message: str = "",
        problems: list[str] = [],
        changes: list[str] = [];
}

def by_version(found: list[PolicyVersion]) -> list[PolicyVersion] {
    return sorted(found, key=lambda (v: PolicyVersion) { v.version; });
}

"""The team policy's versions, oldest first."""
def team_versions -> list[PolicyVersion] {
    return by_version([v for v in [root.shared -->[?:PolicyVersion]] if v.scope == PolicyScope.TEAM]);
}

"""The caller's own policy's versions, oldest first. On the system root (a scheduled job) it
finds none."""
def personal_versions -> list[PolicyVersion] {
    return by_version([v for v in [root -->[?:PolicyVersion]] if v.scope == PolicyScope.PERSONAL]);
}

def versions_of(scope: PolicyScope) -> list[PolicyVersion] {
    return team_versions() if scope == PolicyScope.TEAM else personal_versions();
}

"""The policy in force among `versions` and its number: the newest, or the defaults as
version 0 when none is saved. A stored policy that no longer passes its limits (a limit
tightened since it was saved) gives way to the defaults, so a run never trades on one."""
def current_of(versions: list[PolicyVersion]) -> tuple[Policy, int] {
    if not versions {
        return (Policy(), 0);
    }
    newest = versions[-1];
    return (usable(newest.policy, newest.version), newest.version);
}

def team_policy -> tuple[Policy, int] {
    return current_of(team_versions());
}

"""Version `number` of the policy that drives this work's agent: its owner's inside their scope
(research/credentials.jac), else the team's. The defaults for version 0 or one not on record."""
def policy_version(number: int) -> Policy {
    if number <= 0 {
        return Policy();
    }
    for v in (personal_versions() if current_credentials() is not None else team_versions()) {
        if v.version == number {
            return usable(v.policy, v.version);
        }
    }
    LOG.warning("policy version %s is not on record; using the defaults", number);
    return Policy();
}

def usable(policy: Policy, version: int) -> Policy {
    problems = validate(policy);
    if problems {
        LOG.warning("policy version %s breaks its limits (%s); using the defaults", version, "; ".join(problems)[:300]);
        return Policy();
    }
    return policy;
}

"""Save `policy` as the next version of `scope`, if `base_version` is still the newest and
the policy passes its limits. `source` says how it was made ("form", "chat", "restore")."""
def save_policy(scope: PolicyScope, policy: Policy, base_version: int, source: str = "form", note: str = "") -> SaveResult {
    versions = versions_of(scope);
    (current, number) = current_of(versions);
    if base_version != number {
        return SaveResult(saved=False, version=number, message=f"The policy changed since you opened it (now version {number}). Reload it and make your change again.");
    }
    problems = validate(policy);
    if problems {
        return SaveResult(saved=False, version=number, message="The policy was not saved: " + problems[0], problems=problems);
    }
    edits = changes(current, policy);
    if not edits {
        return SaveResult(saved=False, version=number, message="Nothing changed.");
    }
    made = PolicyVersion(
        scope=scope,
        version=number + 1,
        policy=copy_policy(policy),
        saved_at=utc_now().isoformat(),
        author=TEAM_AUTHOR if scope == PolicyScope.TEAM else "",
        source=source,
        note=" ".join(note.split())[:MAX_NOTE_CHARS],
        changes=edits
    );
    if scope == PolicyScope.TEAM {
        public(root.shared ++> made);
        LOG.info("team policy version %s saved: %s", made.version, "; ".join(edits)[:500]);
    } else {
        root ++> made;
    }
    return SaveResult(saved=True, version=made.version, message=f"Saved as version {made.version}.", changes=edits);
}

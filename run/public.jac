"""Open team-graph nodes to every reader (TDD §3, rule 9; TDD §11).

The scheduled job writes the team graph under root.shared, and other users and anonymous
callers only see a node after it is granted READ. A grant covers one node, not its
subtree, so every public node is created through `public`. Edges need no grant: readers
traverse typed edges to granted nodes (tests/public_tests.jac).

A user's own agent is private: inside its scope (research/credentials.jac) this grants nothing, so
no one but its owner can read what its run writes.
"""
import from research.credentials { current_credentials }

"""Grant READ on a newly attached node and return it.

Wrap the connect expression: `run = public(portfolio +>:Ran():+> Run(...));`.
"""
def public[T](child: T) -> T {
    if current_credentials() is None {
        grant(child, level=AccessLevel.READ);
    }
    return child;
}

"""Spike: does a real free model answer the policy assistant's prompt in its typed shape?

Sends each message below through the real role model, chain, and parser, then through the code
that checks a proposal, and prints what came back. It writes nothing and places no orders. It
spends one to four of the day's free-model requests per message, so about twenty at most.

    set -a && source .env && set +a
    TRADING_AGENT_RUN_SPIKE=1 jac run --no-takeover tests/spikes/policy_chat_spike.jac

A pass means the reply parsed and every message expecting a change got one that passes the limits.
"""
import os;
import sys;
import from agents.policy_assistant { answer_policy_message }
import from models.policy { Policy }
import from policy.chat { apply_edits, metrics_text, rules_text, settings_text }
import from analysis.policy { changes }

glob RUN: str = """Run of 2026-11-03, 2 stocks covered.
AAPL (Information Technology): score 0.30, agreement 0.45; team NO_ACTION; this policy NO_ACTION. Figures: rsi_14 62, momentum_20 0.04.
MSFT (Information Technology, held): score 0.50, agreement 0.80; team ADD; this policy ADD. Figures: rsi_14 74, return_since_entry 0.12.""";

# (message, whether it should propose a change)
glob CASES: list[tuple[str, bool]] = [
    ("Don't buy anything with RSI above 70", True),
    ("Sell a position that has fallen 8% since I bought it", True),
    ("Require 60% agreement before buying", True),
    ("Never buy energy stocks", True),
    ("Why didn't this policy buy AAPL?", False),
    ("What will NVDA's price be next week?", False)
];

def say(line: str) {
    sys.stdout.write(line + "\n");
    sys.stdout.flush();
}

def main {
    policy = Policy();
    passed = 0;
    for (message, wants_change) in CASES {
        say(f"\n> {message}");
        try {
            answer = answer_policy_message(message, "This person's own policy: it only shows what they would have done, and places no orders.", rules_text(policy), settings_text(policy), metrics_text(), RUN, "None yet.");
            say(f"  reply: {answer.reply}");
            (proposal, problems) = apply_edits(policy, answer.edits);
            for line in changes(policy, proposal) {
                say(f"  change: {line}");
            }
            for problem in problems {
                say(f"  problem: {problem}");
            }
            good = (bool(answer.edits) and not problems) if wants_change else not answer.edits;
            say("  PASS" if good else "  FAIL");
            passed += 1 if good else 0;
        } except Exception as e {
            say(f"  FAIL: {type(e).__name__}");
            for line in str(e).splitlines() {
                if "Value error" in line or "Input should be" in line and "instance of" not in line {
                    say(f"  why: {line.strip()[:300]}");
                }
            }
            say(f"  raw: {str(getattr(e, 'raw_output', ''))[:1200]}");
        }
    }
    say(f"\n{passed} of {len(CASES)} passed");
}

with entry {
    if os.environ.get("TRADING_AGENT_RUN_SPIKE") == "1" {
        main();
    }
}

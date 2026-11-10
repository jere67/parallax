"""Decision replay (docs/spikes/2026-11-10-decision-replay.md): which buys the stored votes of
past runs draft under other buy bars and interval coverages.

It reads exports of the live runs (tests/spikes/export_runs.py), never the graph, and makes no
network or model requests, so it is safe beside the live server and costs nothing. A buy here
is the draft the Arbiter would have reviewed; the stored decision shows what the run did.

    TRADING_AGENT_RUN_REPLAY=1 REPLAY_RUNS=team.json,agent.json \
        jac run --no-takeover tests/spikes/decision_replay.jac
"""
import os;
import sys;
import from pathlib { Path }
import from analysis.consensus { ConsensusConfig }
import from models.graph { TradeAction }
import from tests.spikes.decision_backtest { load_runs, replay_picks }

# Not the backtest's TRADING_AGENT_RUN_SPIKE: importing the backtest would start it too.
glob RUN_ENV: str = "TRADING_AGENT_RUN_REPLAY";
glob INTERVALS: list[float] = [0.9, 0.8, 0.68, 0.5];
glob SCORES: list[float] = [0.2, 0.15, 0.1];

def say(line: str) {
    sys.stdout.write(line + "\n");
    sys.stdout.flush();
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        for path in os.environ.get("REPLAY_RUNS", "runs.json").split(",") {
            runs = load_runs(Path(path));
            say(f"== {Path(path).name}: {', '.join(sorted(runs))}");
            for interval in INTERVALS {
                for score in SCORES {
                    config = ConsensusConfig(buy_score=score, interval=interval);
                    buys: list[str] = [];
                    for day in sorted(runs) {
                        for p in replay_picks(runs[day], set(), config) {
                            if p.action == TradeAction.BUY {
                                live = runs[day].tickers[p.ticker].action.value;
                                buys.append(f"{p.ticker} {day} (C {p.score:+.2f}, A {p.agreement:.2f}, low {p.ci_low:+.2f}, run decided {live})");
                            }
                        }
                    }
                    say(f"interval {interval:.0%}, C >= {score:.2f}: {len(buys)} buys");
                    for b in buys {
                        say(f"    {b}");
                    }
                }
            }
        }
    }
}

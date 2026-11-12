"""Switches a server is started with, in a module with no project imports so that any module can
read them without an import cycle."""
import os;

# Set to 1 on a local or CI server to show the seeded demo history and invented market data. No
# agent runs or trades on such a server: the team's jobs and every user's agent skip the day.
glob DEMO_ENV: str = "TRADING_AGENT_DEMO";

def demo_mode -> bool {
    return os.environ.get(DEMO_ENV, "").strip() == "1";
}

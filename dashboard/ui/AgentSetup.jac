"""What the Portfolio page shows before an account has any closing marks: the steps from a new
account to a trading agent, each with its one next action. They run in this order, so they are
numbered."""
import from "@jac/runtime" { Link }
import from "lucide-react" { Check }
import from dashboard.ui.parts { Empty, ErrorBox, Loading, TAP_BUTTON, TAP_QUIET }
import from dashboard.ui.rpc { get_agent_settings, start_my_run }
import from models.accounts { AgentReply, AgentSettings as SettingsData }

def Step(number: int, done: bool, current: bool, title: str, children: any = None) -> JsxElement {
    <li className="flex gap-3 border-t border-line px-4 py-4 first:border-t-0">
        <span className={"num grid size-6 shrink-0 place-items-center rounded-full border text-[12px] font-medium " + ("border-up/40 bg-up/15 text-up" if done else ("border-accent/50 text-accent" if current else "border-line-strong text-faint"))}>
            {<Check size={13} strokeWidth={2.25} aria-label="Done"/> if done else str(number)}
        </span>
        <div className="min-w-0 flex-1">
            <h2 className={"text-[14px] font-medium leading-6 " + ("text-text" if current or done else "text-muted")}>{title}</h2>
            <div className="mt-1 text-[13px] leading-5 text-muted">{children}</div>
        </div>
    </li>
}

def:pub AgentSetup -> JsxElement {
    has settings: SettingsData | None = None,
        error: str = "",
        busy: bool = False,
        message: str = "";

    async can with entry {
        try {
            settings = await get_agent_settings();
        } except Exception as e {
            error = str(e);
        }
    }

    async def start {
        busy = True;
        reply: AgentReply | None = None;
        try {
            reply = await start_my_run();
            if reply is not None {
                settings = reply.settings;
                message = reply.message;
            }
        } except Exception {
            message = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if settings is None {
        return <Loading label="Loading your agent"/>;
    }
    if settings.demo or settings.managed {
        return <Empty title="No closing marks yet">
            Once this agent's first trading day closes, its equity, positions, and orders appear here.
        </Empty>;
    }

    ran: bool = settings.run.status != "" and settings.run.status != "queued";
    started: bool = settings.run.status != "";

    <div className="rise mx-auto flex max-w-[640px] flex-col gap-6">
        <header>
            <h1 className="display text-[36px] leading-10 text-text">Set up your agent</h1>
            <p className="mt-1 text-[13px] leading-5 text-muted">Your portfolio appears here after its first trading day closes.</p>
        </header>
        <ol className="rounded-md border border-line bg-panel">
            <Step number={1} done={settings.ready} current={not settings.ready} title="Connect your keys">
                {if settings.ready {
                    <>Your Alpaca paper account and OpenRouter key are connected.</>
                } else {
                    <div className="flex flex-col items-start gap-2">
                        <span>Your agent runs on your own Alpaca paper account and OpenRouter key.</span>
                        <Link to="/app/settings" className={TAP_BUTTON}>Connect your keys</Link>
                    </div>
                }}
            </Step>
            <Step number={2} done={ran} current={settings.ready and not ran} title="Run your agent">
                {if ran {
                    <>{"Today's run has started. "}<Link to="/app/runs" className="text-accent hover:underline">See its decisions in Runs</Link>.</>
                } elif settings.ready {
                    <div className="flex flex-col items-start gap-2">
                        <span role="status">{message or ("It starts within a minute or two." if started else "It runs by itself at 7:30 a.m. New York time on trading days, or you can start today's run now. A run takes about half an hour.")}</span>
                        {if settings.run.can_start {
                            <button type="button" disabled={busy} onClick={start} className={TAP_BUTTON}>Start today's run</button>
                        }}
                    </div>
                } else {
                    <>It runs by itself at 7:30 a.m. New York time on trading days.</>
                }}
            </Step>
            <Step number={3} done={settings.paper_trading} current={settings.ready and ran and not settings.paper_trading} title="Turn on paper trading, if you want it to">
                {if settings.paper_trading {
                    <>Your agent places paper orders each morning after 9:45 a.m. New York time.</>
                } else {
                    <div className="flex flex-col items-start gap-2">
                        <span>Until then your agent only researches and decides, and places no orders.</span>
                        {if settings.ready { <Link to="/app/settings" className={TAP_QUIET}>Go to paper trading</Link> }}
                    </div>
                }}
            </Step>
        </ol>
    </div>
}

"""Settings (TDD §9, accounts): connect the keys an agent runs on, start its run, choose paper
trading, and change a password. Keys only ever travel from here to the server: the page shows what
the server sends back, which is a hint and the time each was checked."""
import from "@jac/runtime" { jacLogout, useNavigate }
import from "lucide-react" { Check, ExternalLink }
import from dashboard.ui.format { stamp_et }
import from dashboard.ui.parts { ErrorBox, Loading, Panel, TAP_BUTTON, TAP_INPUT, TAP_QUIET }
import from dashboard.ui.rpc { get_agent_settings, remove_agent_keys, save_agent_keys, set_paper_trading, start_my_run }
import from models.accounts { AgentReply, AgentSettings as SettingsData, KeyStatus as KeyData, KeysReply }

glob ALPACA_URL: str = "https://app.alpaca.markets/paper/dashboard/overview";
glob OPENROUTER_URL: str = "https://openrouter.ai/keys";
glob FINNHUB_URL: str = "https://finnhub.io/dashboard";
glob PASSWORD_URL: str = "/user/password";
glob MIN_PASSWORD: int = 8;

def key_named(settings: SettingsData, name: str) -> KeyData | None {
    for k in settings.keys {
        if k.name == name {
            return k;
        }
    }
    return None;
}

def Connected(hint: str, when: str) -> JsxElement {
    <p className="flex flex-wrap items-center gap-x-1.5 text-[12px] leading-[18px] text-up">
        <Check size={13} strokeWidth={2} aria-hidden="true"/>
        <span>{"Connected" + ((" (" + hint + ")") if hint else "")}</span>
        {if when { <span className="text-faint">{"checked " + stamp_et(when)}</span> }}
    </p>
}

def is_connected(settings: SettingsData, name: str) -> bool {
    found = key_named(settings, name);
    return found is not None and found.connected;
}

def KeyInput(label: str, value: str, connected: bool, change: Callable[[str], None]) -> JsxElement {
    <label className="flex flex-col gap-1 text-[12px] text-muted">
        {label}
        <input
            type="password"
            autoComplete="off"
            autoCapitalize="none"
            spellCheck={False}
            placeholder={"Paste to replace" if connected else ""}
            value={value}
            onChange={lambda (e: ChangeEvent) { change(e.target.value); }}
            className={TAP_INPUT + " w-full font-mono"}
        />
    </label>
}

"""One provider's keys: what they are for, where to get them, and their state."""
def ProviderBlock(name: str, about: str, url: str, url_label: str, required: bool, status: KeyData | None, problem: str, can_remove: bool, busy: bool, remove: Callable[[], None], children: any = None) -> JsxElement {
    connected: bool = status is not None and status.connected;
    <div role="group" aria-label={name} className="flex flex-col gap-3 border-b border-line px-4 py-4 last:border-b-0 md:flex-row md:gap-8">
        <div className="md:w-[280px] md:shrink-0">
            <h3 className="text-[14px] font-medium text-text">{name + ("" if required else " (optional)")}</h3>
            <p className="mt-1 text-[12px] leading-[18px] text-muted">{about}</p>
            <a href={url} target="_blank" rel="noopener noreferrer" className="mt-1 inline-flex min-h-6 items-center gap-1 text-[12px] font-medium text-accent hover:underline">
                {url_label}<ExternalLink size={11} strokeWidth={2} aria-hidden="true"/>
            </a>
        </div>
        <div className="flex min-w-0 flex-1 flex-col gap-2.5">
            {children}
            {if problem { <p className="text-[12px] leading-[18px] text-down" role="alert">{problem}</p> }}
            {if connected and status is not None {
                <div className="flex flex-wrap items-center justify-between gap-2">
                    <Connected hint={status.hint} when={status.checked_at}/>
                    {if can_remove {
                        <button type="button" disabled={busy} onClick={remove} className={TAP_QUIET}>Disconnect</button>
                    }}
                </div>
            }}
        </div>
    </div>
}

def KeysPanel(settings: SettingsData, done: Callable[[SettingsData, str], None]) -> JsxElement {
    has alpaca_key: str = "",
        alpaca_secret: str = "",
        openrouter_key: str = "",
        finnhub_key: str = "",
        busy: bool = False,
        message: str = "",
        problems: dict[str, str] = {};

    async def save(e: FormEvent) {
        e.preventDefault();
        busy = True;
        message = "";
        problems = {};
        reply: KeysReply | None = None;
        try {
            reply = await save_agent_keys(alpaca_key, alpaca_secret, openrouter_key, finnhub_key);
            if reply is not None {
                message = reply.message;
                problems = reply.problems;
                done(reply.settings, "");
                if reply.saved {
                    alpaca_key = "";
                    alpaca_secret = "";
                    openrouter_key = "";
                    finnhub_key = "";
                }
            }
        } except Exception {
            message = "The server could not be reached, so nothing was saved. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    async def disconnect(provider: str) {
        busy = True;
        reply: AgentReply | None = None;
        try {
            reply = await remove_agent_keys(provider);
            if reply is not None {
                message = reply.message;
                done(reply.settings, "");
            }
        } except Exception {
            message = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    blocked: bool = not settings.can_store or settings.full;
    any_sent: bool = bool(alpaca_key or alpaca_secret or openrouter_key or finnhub_key);

    <Panel title="Your API keys" pad={False}>
        <form onSubmit={save} autoComplete="off">
            <p className="border-b border-line px-4 py-3 text-[13px] leading-5 text-muted">
                Your agent runs on your own accounts. Each key is checked with its provider, then stored encrypted. It is never shown again, not even to you.
            </p>
            {if not settings.can_store {
                <p className="border-b border-line bg-warn/10 px-4 py-3 text-[13px] leading-5 text-warn" role="alert">This server is not set up to store keys yet. Its operator needs to set PARALLAX_KEYS_SECRET.</p>
            } elif settings.full {
                <p className="border-b border-line bg-warn/10 px-4 py-3 text-[13px] leading-5 text-warn" role="alert">This server is at its limit of agents, so a new one cannot be added right now.</p>
            }}
            <ProviderBlock
                name="Alpaca paper account"
                about="Market data, and the paper account your agent trades. Live accounts are refused."
                url={ALPACA_URL}
                url_label="Get paper keys"
                required={True}
                status={key_named(settings, "ALPACA_SECRET_KEY")}
                problem={problems.get("alpaca", "") or settings.alpaca_problem}
                can_remove={True}
                busy={busy}
                remove={lambda { disconnect("alpaca"); }}
            >
                <div className="grid gap-2.5 sm:grid-cols-2">
                    <KeyInput label="API key ID" value={alpaca_key} connected={is_connected(settings, "ALPACA_API_KEY")} change={lambda (v: str) { alpaca_key = v; }}/>
                    <KeyInput label="Secret key" value={alpaca_secret} connected={is_connected(settings, "ALPACA_SECRET_KEY")} change={lambda (v: str) { alpaca_secret = v; }}/>
                </div>
            </ProviderBlock>
            <ProviderBlock
                name="OpenRouter"
                about="The free AI models your agent thinks with. A full run uses about 460 requests, so buy OpenRouter's one-time $10 credit to raise the free limit from 50 to 1,000 a day."
                url={OPENROUTER_URL}
                url_label="Get a key"
                required={True}
                status={key_named(settings, "OPENROUTER_API_KEY")}
                problem={problems.get("openrouter", "")}
                can_remove={True}
                busy={busy}
                remove={lambda { disconnect("openrouter"); }}
            >
                <KeyInput label="API key" value={openrouter_key} connected={is_connected(settings, "OPENROUTER_API_KEY")} change={lambda (v: str) { openrouter_key = v; }}/>
                {if settings.requests_note { <p className="text-[12px] leading-[18px] text-warn">{settings.requests_note}</p> }}
            </ProviderBlock>
            <ProviderBlock
                name="Finnhub"
                about="Fundamentals, earnings dates, and analyst views. Without it your agent still runs, and those show as gaps its specialists cannot vote on."
                url={FINNHUB_URL}
                url_label="Get a free key"
                required={False}
                status={key_named(settings, "FINNHUB_API_KEY")}
                problem={problems.get("finnhub", "")}
                can_remove={True}
                busy={busy}
                remove={lambda { disconnect("finnhub"); }}
            >
                <KeyInput label="API key" value={finnhub_key} connected={is_connected(settings, "FINNHUB_API_KEY")} change={lambda (v: str) { finnhub_key = v; }}/>
            </ProviderBlock>
            <div className="flex flex-col gap-2 border-t border-line px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                <p className="text-[12px] leading-[18px] text-muted" role="status">{message}</p>
                <button type="submit" disabled={busy or blocked or not any_sent} className={TAP_BUTTON + " shrink-0"}>{"Checking…" if busy else "Check and connect"}</button>
            </div>
        </form>
    </Panel>
}

def run_words(settings: SettingsData) -> str {
    status = settings.run.status;
    if status == "running" {
        return "Working now. A run takes about half an hour.";
    }
    if status == "queued" {
        return "Starting within a minute or two.";
    }
    if status {
        return settings.run.note or "Today's run has finished.";
    }
    return settings.run.note or "Your agent runs by itself at 7:30 a.m. New York time on trading days. You can also start today's run now.";
}

def RunPanel(settings: SettingsData, done: Callable[[SettingsData, str], None]) -> JsxElement {
    has busy: bool = False,
        message: str = "";

    async def start {
        busy = True;
        reply: AgentReply | None = None;
        try {
            reply = await start_my_run();
            if reply is not None {
                message = reply.message;
                done(reply.settings, "");
            }
        } except Exception {
            message = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    <Panel title="Today's run">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-[13px] leading-5 text-muted" role="status">{message or run_words(settings)}</p>
            <button type="button" disabled={busy or not settings.run.can_start} onClick={start} className={TAP_BUTTON + " shrink-0"}>Start today's run</button>
        </div>
    </Panel>
}

"""Paper trading is off until its owner turns it on here, with a second step that says what it
means. Turning it off takes one step, since that is always the safe way."""
def TradingPanel(settings: SettingsData, done: Callable[[SettingsData, str], None]) -> JsxElement {
    has confirming: bool = False,
        busy: bool = False,
        message: str = "";

    async def choose(on: bool) {
        busy = True;
        reply: AgentReply | None = None;
        try {
            reply = await set_paper_trading(on);
            if reply is not None {
                message = reply.message;
                confirming = False;
                done(reply.settings, "");
            }
        } except Exception {
            message = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    paused = settings.paper_trading and bool(settings.alpaca_problem);
    <Panel title="Paper trading" aside={<span className={"font-medium " + ("text-warn" if paused else ("text-accent" if settings.paper_trading else "text-muted"))}>{"Paused" if paused else ("On" if settings.paper_trading else "Off")}</span>}>
        <div className="flex flex-col gap-3">
            <p className="text-[13px] leading-5 text-muted">
                {"Your agent places no orders until its Alpaca keys open a paper account of its own. It keeps researching and deciding meanwhile." if paused else ("Your agent places paper orders on your Alpaca account each morning after 9:45 a.m. New York time, within your policy's limits." if settings.paper_trading else "Your agent researches and decides, but places no orders. Turn this on to have it trade your Alpaca paper account.")}
            </p>
            {if message { <p className="text-[13px] leading-5 text-text" role="status">{message}</p> }}
            {if settings.paper_trading {
                <button type="button" disabled={busy} onClick={lambda { choose(False); }} className={TAP_QUIET + " self-start"}>Turn off paper trading</button>
            } elif confirming {
                <div className="flex flex-col gap-3 rounded-md border border-accent/40 bg-accent/10 p-3">
                    <p className="text-[13px] leading-5 text-text">
                        {"From its next morning run, your agent buys and sells on your paper account with no further approval from you. Only simulated money moves." + ("" if settings.trading_started else " Your paper account must be empty to start, so your agent and its benchmarks begin alike.")}
                    </p>
                    <div className="flex flex-wrap gap-2">
                        <button type="button" disabled={busy} onClick={lambda { choose(True); }} className={TAP_BUTTON}>{"Please wait…" if busy else "Turn on paper trading"}</button>
                        <button type="button" disabled={busy} onClick={lambda { confirming = False; }} className={TAP_QUIET}>Keep it off</button>
                    </div>
                </div>
            } else {
                <button type="button" disabled={not settings.ready or settings.demo or bool(settings.alpaca_problem)} onClick={lambda { confirming = True; message = ""; }} className={TAP_BUTTON + " self-start"}>Turn on paper trading</button>
            }}
        </div>
    </Panel>
}

"""The admin's agent runs on the server's own keys, so there is nothing to connect."""
def ManagedPanel(settings: SettingsData) -> JsxElement {
    <Panel title="Your agent">
        <p className="text-[13px] leading-5 text-muted">
            {"This is the server's own agent. It runs on the keys in the server's environment, and its trading is " + ("on" if settings.paper_trading else "off") + ", which is set on the server."}
        </p>
    </Panel>
}

"""The runtime keeps its token out of reach, so this asks it through the same request it would
send, with the stored token."""
async def change_password(current: str, fresh: str) -> int {
    token = localStorage.getItem("jac_token") or "";
    response: any = None;
    response = await fetch(PASSWORD_URL, {"method": "PUT", "headers": {"Content-Type": "application/json", "Authorization": "Bearer " + token}, "body": JSON.stringify({"current_password": current, "new_password": fresh})});
    return response.status;
}

def AccountPanel(leave: Callable[[], None]) -> JsxElement {
    has current: str = "",
        fresh: str = "",
        busy: bool = False,
        message: str = "",
        problem: str = "";

    async def save(e: FormEvent) {
        e.preventDefault();
        busy = True;
        message = "";
        problem = "";
        status: int = 0;
        try {
            status = await change_password(current, fresh);
            if status >= 200 and status < 300 {
                message = "Password changed.";
                current = "";
                fresh = "";
            } else {
                problem = "The password was not changed. Check your current password.";
            }
        } except Exception {
            problem = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    <Panel title="Account">
        <div role="group" aria-label="Account" className="flex flex-col gap-4">
            <form onSubmit={save} className="grid gap-2.5 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                <label className="flex flex-col gap-1 text-[12px] text-muted">
                    Current password
                    <input type="password" autoComplete="current-password" value={current} onChange={lambda (e: ChangeEvent) { current = e.target.value; }} className={TAP_INPUT + " w-full"}/>
                </label>
                <label className="flex flex-col gap-1 text-[12px] text-muted">
                    New password
                    <input type="password" autoComplete="new-password" value={fresh} onChange={lambda (e: ChangeEvent) { fresh = e.target.value; }} className={TAP_INPUT + " w-full"}/>
                </label>
                <button type="submit" disabled={busy or not current or len(fresh) < MIN_PASSWORD} className={TAP_BUTTON}>Change password</button>
            </form>
            {if problem { <p className="text-[13px] text-down" role="alert">{problem}</p> }}
            {if message { <p className="text-[13px] text-muted" role="status">{message}</p> }}
            <button type="button" onClick={leave} className={TAP_QUIET + " self-start"}>Log out</button>
        </div>
    </Panel>
}

def:pub SettingsPage -> JsxElement {
    has settings: SettingsData | None = None,
        error: str = "";

    nav = useNavigate();

    async can with entry {
        try {
            settings = await get_agent_settings();
        } except Exception as e {
            error = str(e);
        }
    }

    def leave {
        jacLogout();
        nav("/", {"replace": True});
    }

    def update(fresh: SettingsData, _note: str) {
        settings = fresh;
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if settings is None {
        return <Loading label="Loading your settings"/>;
    }

    <div className="rise mx-auto flex max-w-[860px] flex-col gap-6">
        <header>
            <h1 className="display text-[36px] leading-10 text-text">Settings</h1>
            <p className="mt-1 text-[13px] leading-5 text-muted">Connect your keys, then start your agent.</p>
        </header>
        {if settings.demo {
            <p className="rounded-md border border-warn/25 bg-warn/10 px-3 py-2 text-[13px] leading-5 text-warn">This server only shows demo history, so no agent runs or trades here.</p>
        }}
        {<ManagedPanel settings={settings}/> if settings.managed else <KeysPanel settings={settings} done={update}/>}
        <RunPanel settings={settings} done={update}/>
        {if not settings.managed { <TradingPanel settings={settings} done={update}/> }}
        <AccountPanel leave={leave}/>
    </div>
}

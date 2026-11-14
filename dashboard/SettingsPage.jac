"""Settings (TDD §9, accounts): connect the keys an agent runs on, start its run, choose paper
trading, and change a password. Keys only ever travel from here to the server: the page shows what
the server sends back, which is a hint and the time each was checked."""
import from "@jac/runtime" { jacLogout, useNavigate }
import from "react" { useEffect }
import from "lucide-react" { Check, ChevronDown, ExternalLink }
import from dashboard.ui.brand { DOCS_URL }
import from dashboard.ui.format { stamp_et }
import from dashboard.ui.parts { ErrorBox, Loading, Panel, TAP_BUTTON, TAP_INPUT, TAP_QUIET }
import from dashboard.ui.rpc { get_agent_settings, get_transfer_status, remove_agent_keys, save_agent_keys, set_paper_trading, start_my_run, start_transfer }
import from models.accounts { AgentReply, AgentSettings as SettingsData, KeyStatus as KeyData, KeysReply, TransferStatus }

# Where each provider makes its keys. A page that needs an account sends a signed-out visitor to
# sign in or sign up, then back to it.
glob ALPACA_URL: str = "https://app.alpaca.markets/paper/dashboard/overview";
glob ALPACA_SIGNUP_URL: str = "https://app.alpaca.markets/signup";
glob OPENROUTER_URL: str = "https://openrouter.ai/settings/keys";
glob OPENROUTER_CREDITS_URL: str = "https://openrouter.ai/settings/credits";
glob FINNHUB_URL: str = "https://finnhub.io/dashboard";
glob FINNHUB_SIGNUP_URL: str = "https://finnhub.io/register";

"""How to make each provider's key, in order. A step's `href` is a page it names; `label` is its link text."""
glob ALPACA_STEPS: list[dict[str, str]] = [
    {"text": "Sign up for Alpaca, or log in.", "label": "Sign up", "href": ALPACA_SIGNUP_URL},
    {"text": "Open the paper dashboard below. The account menu at the top left should say Paper, not Live."},
    {"text": "Under API Keys, choose Generate New Keys. Copy the key ID and the secret; Alpaca shows the secret only once."}
];
glob OPENROUTER_STEPS: list[dict[str, str]] = [
    {"text": "Open the keys page below, and sign up or log in. An account is free."},
    {"text": "Choose Create Key, name it Parallax, and copy the key. OpenRouter shows it only once."},
    {"text": "Optional: buy the one-time $10 credit, which raises the free-model limit from 50 to 1,000 requests a day. A full run uses about 460.", "label": "Buy credits", "href": OPENROUTER_CREDITS_URL}
];
glob FINNHUB_STEPS: list[dict[str, str]] = [
    {"text": "Sign up for a free Finnhub account, and confirm your email.", "label": "Sign up", "href": FINNHUB_SIGNUP_URL},
    {"text": "Open the dashboard below. Your API key is at the top; copy it."}
];
glob PASSWORD_URL: str = "/user/password";
glob EXPORT_GUIDE_URL: str = DOCS_URL + "guide/deploy#bring-your-records-along";
# How often the page asks how a move is going.
glob MOVE_POLL_MS: int = 3000;
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

"""A link that opens a provider's page in a new tab."""
def OutLink(href: str, children: any = None) -> JsxElement {
    <a href={href} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-medium text-accent hover:underline">
        {children}<ExternalLink size={11} strokeWidth={2} aria-hidden="true"/>
    </a>
}

"""The numbered steps to make a provider's key, then a button to the page that makes it."""
def KeySteps(steps: list[dict[str, str]], url: str, url_label: str) -> JsxElement {
    <div className="flex flex-col gap-3">
        <ol className="flex flex-col gap-2">
            {for (i, step) in enumerate(steps) {
                <li key={i} className="flex gap-2 text-[12px] leading-[18px] text-muted">
                    <span className="num flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-full bg-accent/15 text-[11px] font-medium text-accent" aria-hidden="true">{str(i + 1)}</span>
                    <span>
                        {step["text"]}
                        {if step.get("href") { <span>{" "}<OutLink href={step["href"]}>{step["label"]}</OutLink></span> }}
                    </span>
                </li>
            }}
        </ol>
        <a href={url} target="_blank" rel="noopener noreferrer" className={TAP_QUIET + " w-full"}>
            {url_label}<ExternalLink size={13} strokeWidth={2} aria-hidden="true"/>
        </a>
    </div>
}

"""How to get a provider's key: laid out while it has none, and folded under "Need a new key?" once
it is connected, opening by itself when the provider reports a problem with the key."""
def KeyGuide(steps: list[dict[str, str]], url: str, url_label: str, connected: bool, problem: str) -> JsxElement {
    if not connected {
        return <div className="mt-3 rounded-md border border-line bg-panel-2 p-3">
            <p className="mb-2.5 text-[12px] font-medium text-text">How to get your key</p>
            <KeySteps steps={steps} url={url} url_label={url_label}/>
        </div>;
    }
    <details className="group mt-2" open={bool(problem)}>
        <summary className="inline-flex min-h-6 cursor-pointer list-none items-center gap-1 text-[12px] font-medium text-accent hover:underline [&::-webkit-details-marker]:hidden">
            Need a new key?
            <ChevronDown size={13} strokeWidth={2} aria-hidden="true" className="transition-transform duration-150 group-open:rotate-180"/>
        </summary>
        <div className="mt-2 rounded-md border border-line bg-panel-2 p-3">
            <KeySteps steps={steps} url={url} url_label={url_label}/>
        </div>
    </details>
}

"""One provider's keys: what they are for, how to get them, and their state."""
def ProviderBlock(name: str, about: str, url: str, url_label: str, steps: list[dict[str, str]], required: bool, status: KeyData | None, problem: str, can_remove: bool, busy: bool, remove: Callable[[], None], children: any = None) -> JsxElement {
    connected: bool = status is not None and status.connected;
    <div role="group" aria-label={name} className="flex flex-col gap-3 border-b border-line px-4 py-4 last:border-b-0 md:flex-row md:gap-8">
        <div className="md:w-[280px] md:shrink-0">
            <h3 className="text-[14px] font-medium text-text">{name + ("" if required else " (optional)")}</h3>
            <p className="mt-1 text-[12px] leading-[18px] text-muted">{about}</p>
            <KeyGuide steps={steps} url={url} url_label={url_label} connected={connected} problem={problem}/>
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
                url_label="Open Alpaca's paper dashboard"
                steps={ALPACA_STEPS}
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
                about="The free AI models your agent thinks with."
                url={OPENROUTER_URL}
                url_label="Open OpenRouter's keys page"
                steps={OPENROUTER_STEPS}
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
                url_label="Open Finnhub's dashboard"
                steps={FINNHUB_STEPS}
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

"""The file's contents as base64, which is how a move travels to the server."""
def read_base64(file: any) -> any {
    return new(Promise, lambda (resolve: any, reject: any) {
        reader: any = new(FileReader);  # jac:ignore[E1053]
        reader.onload = lambda { resolve.call(None, String(reader.result).split(",")[1] or ""); };
        reader.onerror = lambda { reject.call(None, reader.error); };
        reader.readAsDataURL(file);
    });
}

"""Moving another server's records here: an admin's step on a server that has not run yet. The
move replaces this server's accounts too, so once it lands the page signs out."""
def MovePanel(moved: Callable[[], None]) -> JsxElement {
    has status: TransferStatus | None = None,
        file: any = None,
        confirming: bool = False,
        busy: bool = False,
        problem: str = "";

    async can with entry {
        try {
            status = await get_transfer_status();
        } except Exception {
            status = None;
        }
    }

    async def check {
        found: TransferStatus | None = None;
        try {
            found = await get_transfer_status();
        } except Exception {
            # The accounts changed under this session: the move landed.
            moved();
            return;
        }
        if found is not None and found.state == "done" {
            moved();
            return;
        }
        status = found;
    }

    running: bool = status is not None and status.state == "running";
    useEffect(lambda {
        timer = window.setInterval(lambda { if running { check(); } }, MOVE_POLL_MS);
        return lambda { window.clearInterval(timer); };
    }, [running]);

    async def start {
        busy = True;
        problem = "";
        try {
            data = await read_base64(file);
            reply = await start_transfer(data);
            if reply is not None {
                status = reply;
                confirming = False;
                if reply.state == "refused" {
                    problem = reply.message;
                }
            }
        } except Exception {
            problem = "The file could not be sent. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    if status is None or not (status.ready or status.state in ["running", "failed", "done"]) {
        return <></>;
    }
    state_words = status.message if status.state in ["running", "failed", "done"] else "";
    <Panel title="Bring records from another server">
        <div className="flex flex-col gap-3">
            <p className="text-[13px] leading-5 text-muted">
                {"This server has not run yet, so it can take another server's records: every run, decision, order, and agent, and the accounts that sign in to them. Export them on the old server with scripts/export-data.sh, then choose the file here. "}
                <a href={EXPORT_GUIDE_URL} target="_blank" rel="noopener noreferrer" className="font-medium text-accent hover:underline">How to export</a>
            </p>
            {if state_words {
                <p className={"text-[13px] leading-5 " + ("text-down" if status.state == "failed" else "text-text")} role="status">{state_words}</p>
            }}
            {if problem { <p className="text-[13px] leading-5 text-down" role="alert">{problem}</p> }}
            {if status.ready and not running {
                <div className="flex flex-col gap-3">
                    <label className="flex flex-col gap-1 text-[12px] text-muted">
                        Export file
                        <input
                            type="file"
                            accept=".gz,.json,application/gzip,application/json"
                            onChange={lambda (e: ChangeEvent) { picked: any = e.target.files; file = picked[0] if picked and picked.length else None; confirming = False; problem = ""; }}
                            className="text-[13px] text-text file:mr-3 file:min-h-9 file:cursor-pointer file:rounded-md file:border file:border-line file:bg-panel-2 file:px-3 file:text-[13px] file:font-medium file:text-text"
                        />
                    </label>
                    {if confirming {
                        <div className="flex flex-col gap-3 rounded-md border border-accent/40 bg-accent/10 p-3">
                            <p className="text-[13px] leading-5 text-text">The file's records and accounts replace this server's. Afterwards you are signed out, and everyone signs in with their accounts from the old server.</p>
                            <div className="flex flex-wrap gap-2">
                                <button type="button" disabled={busy} onClick={start} className={TAP_BUTTON}>{"Sending…" if busy else "Move the records here"}</button>
                                <button type="button" disabled={busy} onClick={lambda { confirming = False; }} className={TAP_QUIET}>Cancel</button>
                            </div>
                        </div>
                    } else {
                        <button type="button" disabled={not file} onClick={lambda { confirming = True; problem = ""; }} className={TAP_BUTTON + " self-start"}>Move records here</button>
                    }}
                </div>
            }}
        </div>
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
        {if settings.managed and not settings.demo { <MovePanel moved={leave}/> }}
        <AccountPanel leave={leave}/>
    </div>
}

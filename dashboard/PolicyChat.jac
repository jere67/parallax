"""The policy chat: ask why a decision went the way it did, or say what to change in plain
English and get a proposal to apply or discard. A sidebar on a wide screen and a bottom sheet on
a phone, one component either way, so a half-written message survives the sheet closing.

Everything here is a private endpoint, reached through the runtime RPC helper because the
pinned Jac build cannot seal implicit bridges for private endpoints. A call is never sent while
signed out: a 401 reloads the page (see ReportsPage.jac)."""
import from "@jac/runtime" { jacIsLoggedIn }
import from dashboard.ui.retry { call_function }
import from "lucide-react" { ArrowUp, Check, X }
import from "react" { useEffect, useRef }
import from dashboard.ui.parts { TAP_BUTTON, TAP_INPUT, TAP_QUIET, TONE_ACCENT, TONE_QUIET, TONE_UP, TONE_WARN, PILL_BASE }
import from models.policy_views { ChatActionReply as ChatReply, ChatState as ChatData, ChatTurnView as TurnData, PolicyDoc as DocData }

glob POLL_MS: int = 1500;
glob STATUS_WORDS: dict[str, str] = {"applied": "Applied", "discarded": "Discarded", "stale": "Out of date", "invalid": "Cannot apply"};
glob STATUS_TONES: dict[str, str] = {"applied": TONE_UP, "discarded": TONE_QUIET, "stale": TONE_WARN, "invalid": TONE_WARN};
glob SUGGESTIONS: list[str] = [
    "Why does this policy differ from the team's today?",
    "Don't buy anything with RSI above 70",
    "Sell a position that has fallen 8% since I bought it"
];

def contract(name: str) -> dict[str, str] {
    return {"contract": "[\"trading-agent\",\"policy/chat.jac\",\"func\",\"" + name + "\"]"};
}

async def load_chat(scope: str) -> ChatData | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("get_policy_chat", {"scope": scope}, contract("get_policy_chat"));
}

async def send_message(scope: str, text: str) -> ChatData | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function("send_policy_message", {"scope": scope, "text": text}, contract("send_policy_message"));
}

async def act_on(name: str, turn_id: str) -> ChatReply | None {
    if not jacIsLoggedIn() { return None; }
    return await call_function(name, {"turn_id": turn_id}, contract(name));
}

"""What a proposal would change, with its way to be applied or discarded."""
def Proposal(turn: TurnData, busy: bool, blocked: bool, apply: Callable[[str], None], discard: Callable[[str], None]) -> JsxElement {
    open_now = turn.status == "proposed";
    <div className="mt-2 rounded-md border border-line-strong bg-panel p-3" data-testid="proposal">
        <div className="flex items-center justify-between gap-2">
            <div className="text-[11px] font-medium uppercase tracking-[0.05em] text-faint">{"Proposed change" if len(turn.changes) > 0 else "Proposal"}</div>
            {if not open_now and STATUS_WORDS.get(turn.status) {
                <span className={PILL_BASE + " " + STATUS_TONES.get(turn.status, TONE_QUIET)}>
                    {STATUS_WORDS[turn.status] + (" as v" + str(turn.applied_version) if turn.status == "applied" else "")}
                </span>
            }}
        </div>
        {if len(turn.changes) > 0 {
            <ul className="mt-1.5 flex flex-col gap-1 text-[13px]">
                {for change in turn.changes { <li key={change}>{change}</li> }}
            </ul>
        }}
        {if len(turn.impact) > 0 {
            <div className="mt-2 border-t border-line pt-2 text-[12px] text-muted">
                {for line in turn.impact { <div key={line}>{line}</div> }}
            </div>
        }}
        {if len(turn.problems) > 0 {
            <ul className="mt-1.5 flex flex-col gap-1 text-[12px] text-warn">
                {for problem in turn.problems { <li key={problem}>{problem}</li> }}
            </ul>
        }}
        {if open_now {
            <div className="mt-3">
                {if blocked { <p className="mb-2 text-[12px] text-warn">Save or discard your edits in the form first.</p> }}
                <div className="flex gap-2">
                    <button type="button" disabled={busy or blocked} onClick={lambda { apply(turn.id); }} className={TAP_BUTTON + " flex-1"}><Check size={15} strokeWidth={2} aria-hidden="true"/>Apply</button>
                    <button type="button" disabled={busy} onClick={lambda { discard(turn.id); }} className={TAP_QUIET + " flex-1"}><X size={15} strokeWidth={2} aria-hidden="true"/>Discard</button>
                </div>
            </div>
        }}
    </div>
}

def Bubble(turn: TurnData, busy: bool, blocked: bool, apply: Callable[[str], None], discard: Callable[[str], None]) -> JsxElement {
    mine = turn.role == "user";
    proposal = len(turn.changes) > 0 or len(turn.problems) > 0;
    <li className={"flex flex-col " + ("items-end" if mine else "items-stretch")}>
        <div className={("max-w-[85%] rounded-lg bg-accent-soft px-3 py-2 text-text" if mine else "text-text") + " text-[13px] leading-5 " + ("text-warn" if turn.status == "error" else "")}>{turn.text}</div>
        {if proposal { <Proposal turn={turn} busy={busy} blocked={blocked} apply={apply} discard={discard}/> }}
    </li>
}

"""`open_sheet` shows it on a phone, and `close` hides it again. `blocked` is true while the form
holds unsaved edits, since applying a proposal would replace them. `saved` gets the policy a
proposal saved."""
def:pub PolicyChat(scope: str, whose: str, blocked: bool, open_sheet: bool, close: Callable[[], None], saved: Callable[[DocData], None]) -> JsxElement {
    has chat: ChatData | None = None,
        text: str = "",
        busy: bool = False,
        error: str = "";

    end = useRef(None);

    async def refresh {
        fresh: ChatData | None = None;
        try {
            fresh = await load_chat(scope);
            if fresh is not None {
                chat = fresh;
                error = "";
            }
        } except Exception {
            error = "Could not reach the assistant. Check your connection and try again.";
        }
    }

    async can with [scope] entry {
        chat = None;
        await refresh();
    }

    pending: bool = chat is not None and chat.pending;
    turn_count: int = len(chat.turns) if chat is not None else 0;

    # Ask again while an answer is on its way.
    useEffect(lambda {
        if not pending { return; }
        timer = setInterval(refresh, POLL_MS);
        return lambda { clearInterval(timer); };
    }, [pending, scope]);

    useEffect(lambda {
        if end.current {
            end.current.scrollIntoView({"block": "nearest"});
        }
    }, [turn_count, pending, open_sheet]);

    async def send(message: str) {
        if not message.strip() { return; }
        busy = True;
        error = "";
        fresh: ChatData | None = None;
        try {
            fresh = await send_message(scope, message);
            if fresh is not None {
                chat = fresh;
                text = "";
            }
        } except Exception {
            error = "Could not send that. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    async def act(name: str, turn_id: str) {
        busy = True;
        error = "";
        reply: ChatReply | None = None;
        try {
            reply = await act_on(name, turn_id);
            if reply is not None {
                if reply.chat.scope { chat = reply.chat; }
                if not reply.ok { error = reply.message; }
                if reply.ok and reply.doc is not None { saved(reply.doc); }
            }
        } except Exception {
            error = "Could not do that. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    def submit(e: FormEvent) {
        e.preventDefault();
        send(text);
    }

    can_send: bool = chat is not None and chat.available and not pending;

    <div>
        {if open_sheet {
            <div className="fixed inset-0 z-40 bg-black/40 lg:hidden" onClick={lambda { close(); }} aria-hidden="true"></div>
        }}
        <section
            aria-label="Policy assistant"
            className={("max-lg:flex " if open_sheet else "max-lg:hidden ") + "flex-col overflow-hidden border-line bg-panel max-lg:fixed max-lg:inset-x-0 max-lg:bottom-0 max-lg:z-50 max-lg:h-[85dvh] max-lg:rounded-t-xl max-lg:border-t max-lg:pb-[env(safe-area-inset-bottom)] lg:sticky lg:top-16 lg:flex lg:h-[calc(100dvh-5.5rem)] lg:rounded-md lg:border"}
        >
            <header className="flex min-h-12 shrink-0 items-center justify-between gap-2 border-b border-line px-4 py-2">
                <div className="min-w-0">
                    <h2 className="text-[15px] font-medium leading-5">Policy assistant</h2>
                    <p className="truncate text-[11px] text-faint">{whose}</p>
                </div>
                <button type="button" onClick={lambda { close(); }} className="press grid size-11 shrink-0 place-items-center rounded-md text-muted hover:bg-hover lg:hidden" aria-label="Close the assistant"><X size={18} strokeWidth={1.75}/></button>
            </header>
            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 py-3" aria-live="polite">
                {if chat is None and not error {
                    <p className="text-[13px] text-muted">Loading…</p>
                }}
                {if chat is not None and len(chat.turns) == 0 {
                    <div className="flex flex-col gap-2">
                        <p className="text-[13px] text-muted">Say what you want in plain English. I propose the change and show what it would have done; nothing is saved until you apply it.</p>
                        {if chat.available {
                            <div className="flex flex-col items-start gap-1.5 pt-1">
                                {for s in SUGGESTIONS {
                                    <button key={s} type="button" disabled={busy} onClick={lambda { send(s); }} className={PILL_BASE + " press min-h-9 whitespace-normal rounded-[14px] px-3 py-1.5 text-left text-[12px] " + TONE_ACCENT}>{s}</button>
                                }}
                            </div>
                        }}
                    </div>
                }}
                {if chat is not None {
                    <ul className="flex flex-col gap-3">
                        {for turn in chat.turns {
                            <Bubble key={turn.id} turn={turn} busy={busy} blocked={blocked} apply={lambda (id: str) { act("apply_policy_proposal", id); }} discard={lambda (id: str) { act("discard_policy_proposal", id); }}/>
                        }}
                    </ul>
                }}
                {if pending {
                    <p className="mt-3 animate-pulse text-[13px] text-muted" role="status">Thinking. Free models can take up to a minute.</p>
                }}
                <div ref={end}></div>
            </div>
            <div className="shrink-0 border-t border-line p-3">
                {if error { <p className="mb-2 text-[12px] text-down" role="alert">{error}</p> }}
                {if chat is not None and chat.note { <p className="mb-2 text-[12px] text-warn">{chat.note}</p> }}
                <form onSubmit={submit} className="flex items-end gap-2">
                    <input
                        type="text"
                        aria-label="Message the policy assistant"
                        placeholder={"Ask or describe a change" if can_send or chat is None else "Unavailable right now"}
                        maxLength={500}
                        disabled={not can_send}
                        value={text}
                        onChange={lambda (e: ChangeEvent) { text = e.target.value; }}
                        className={TAP_INPUT + " disabled:opacity-60"}
                    />
                    <button type="submit" disabled={not can_send or busy or not text.strip()} className={TAP_BUTTON + " !px-3"} aria-label="Send"><ArrowUp size={16} strokeWidth={2}/></button>
                </form>
                {if chat is not None and chat.daily_limit > 0 {
                    <p className="num mt-1.5 text-[11px] text-faint">{str(chat.remaining) + " of " + str(chat.daily_limit) + " messages left today"}</p>
                }}
            </div>
        </section>
    </div>
}

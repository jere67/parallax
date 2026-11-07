"""Logging in and creating an account: one centered card under the drifting arcs, with the
product's name above it. Email and password only, until other ways work; the form has no control
that does nothing. A password reset by email needs a mail sender, which this server does not have,
so the page does not offer one."""
import from "@jac/runtime" { Link, Navigate, SignupResult, jacIsLoggedIn, jacLogin, jacSignup, useLocation, useNavigate }
import from "lucide-react" { Eye, EyeOff }
import from dashboard.ui.brand { DISCLAIMER, PRODUCT, ThemeSwitch, Wordmark }

glob MIN_PASSWORD: int = 8;
glob FIELD: str = "min-h-11 w-full rounded-md border border-line-strong bg-bg px-3 text-text outline-none transition-colors duration-150 focus:border-accent max-md:text-[16px]";

"""Where to go after logging in: the page the reader was sent here from, if it is inside the app,
so a crafted link cannot send them elsewhere."""
def next_page(search: str, fallback: str) -> str {
    wanted: any = new(URLSearchParams, search).get("next") or "";  # jac:ignore[E1053]
    return wanted if wanted == "/app" or wanted.startsWith("/app/") else fallback;
}

"""Words for a failed sign-up. The server's message names the case worth telling apart."""
def signup_words(error: str) -> str {
    if "exist" in error.lower() or "already" in error.lower() {
        return "An account with this email already exists. Log in instead.";
    }
    return "This account could not be created. Check your email and password, then try again.";
}

"""Slow arcs across the top of the page, one for each specialist, drifting at different speeds."""
def Arcs -> JsxElement {
    <svg className="auth-arcs pointer-events-none absolute inset-x-0 top-0 h-[300px] w-full text-accent" viewBox="0 0 1200 300" preserveAspectRatio="none" aria-hidden="true">
        {for (i, path) in enumerate([
            "M-100 190 C 200 70, 420 250, 700 130 S 1120 60, 1300 170",
            "M-100 150 C 240 40, 460 220, 720 100 S 1100 40, 1300 130",
            "M-100 110 C 180 10, 500 180, 760 70 S 1140 10, 1300 90",
            "M-100 70 C 220 -20, 440 140, 700 40 S 1080 -20, 1300 50",
            "M-100 225 C 260 110, 400 280, 680 170 S 1160 100, 1300 205"
        ]) {
            <path key={i} d={path} className={"auth-arc auth-arc-" + str(i)} fill="none" stroke="currentColor" strokeWidth="1" vectorEffect="non-scaling-stroke"/>
        }}
    </svg>
}

def:pub AuthPage(creating: bool = False) -> JsxElement {
    has email: str = "",
        password: str = "",
        showing: bool = False,
        busy: bool = False,
        error: str = "";

    nav = useNavigate();
    search = useLocation().search;

    if jacIsLoggedIn() {
        return <Navigate to={next_page(search, "/app")} replace={True}/>;
    }

    valid: bool = bool(email.strip()) and (len(password) >= MIN_PASSWORD if creating else bool(password));

    async def submit(e: FormEvent) {
        e.preventDefault();
        if not valid or busy {
            return;
        }
        busy = True;
        error = "";
        made: SignupResult | None = None;
        ok: bool = False;
        name = email.strip();
        try {
            if creating {
                made = await jacSignup(name, password);
                if not made.success {
                    error = signup_words(str(made.error or ""));
                    return;
                }
            }
            ok = await jacLogin(name, password);
            if ok {
                nav(next_page(search, "/app/settings" if creating else "/app"), {"replace": True});
            } else {
                error = "That email and password do not match an account.";
            }
        } except Exception {
            error = "The server could not be reached. Try again in a moment.";
        } finally {
            busy = False;
        }
    }

    suffix: str = search or "";

    <div className="relative flex min-h-dvh flex-col overflow-hidden pt-[env(safe-area-inset-top)]">
        <Arcs/>
        <header className="relative mx-auto flex h-16 w-full max-w-[1200px] items-center justify-between px-4 sm:px-6 lg:px-8">
            <Wordmark/>
            <ThemeSwitch/>
        </header>
        <main className="relative flex flex-1 flex-col items-center px-4 pb-10 pt-10 sm:pt-16">
            <div className="w-full max-w-[420px] rounded-lg border border-line bg-panel shadow-overlay">
                <div className="px-5 pb-6 pt-7 sm:px-8 sm:pt-8">
                    <h1 className="text-[22px] font-medium leading-7 text-text">{"Create your account" if creating else "Log in to your account"}</h1>
                    {if creating {
                        <p className="mt-1.5 text-[13px] leading-5 text-muted">Next, you connect your own API keys, and your agent runs on them.</p>
                    }}
                    {if error {
                        <p className="mt-4 rounded-md border border-down/35 bg-down/10 px-3 py-2 text-[13px] leading-5 text-down" role="alert">{error}</p>
                    }}
                    <form onSubmit={submit} className="mt-5 flex flex-col gap-4" noValidate={True}>
                        <div className="flex flex-col gap-1.5">
                            <label htmlFor="auth-email" className="text-[13px] font-medium text-text">Email</label>
                            <input
                                id="auth-email"
                                type={"email" if creating else "text"}
                                autoComplete="username"
                                autoCapitalize="none"
                                spellCheck={False}
                                autoFocus={True}
                                value={email}
                                onChange={lambda (e: ChangeEvent) { email = e.target.value; }}
                                className={FIELD}
                            />
                        </div>
                        <div className="flex flex-col gap-1.5">
                            <label htmlFor="auth-password" className="text-[13px] font-medium text-text">Password</label>
                            <div className="relative">
                                <input
                                    id="auth-password"
                                    type={"text" if showing else "password"}
                                    autoComplete={"new-password" if creating else "current-password"}
                                    autoCapitalize="none"
                                    spellCheck={False}
                                    value={password}
                                    onChange={lambda (e: ChangeEvent) { password = e.target.value; }}
                                    className={FIELD + " pr-11"}
                                />
                                <button
                                    type="button"
                                    onClick={lambda { showing = not showing; }}
                                    aria-label={"Hide password" if showing else "Show password"}
                                    className="press absolute inset-y-0 right-0 grid w-11 place-items-center rounded-md text-muted hover:text-text"
                                >
                                    {<EyeOff size={16} strokeWidth={1.75} aria-hidden="true"/> if showing else <Eye size={16} strokeWidth={1.75} aria-hidden="true"/>}
                                </button>
                            </div>
                            {if creating {
                                <p className="text-[12px] text-faint">{"At least " + str(MIN_PASSWORD) + " characters."}</p>
                            }}
                        </div>
                        <button
                            type="submit"
                            disabled={not valid or busy}
                            className="press mt-1 min-h-11 w-full rounded-md bg-accent px-4 text-[14px] font-medium text-bg transition-opacity duration-150 disabled:opacity-45"
                        >
                            {"Please wait…" if busy else ("Create account" if creating else "Log in")}
                        </button>
                    </form>
                </div>
                <div className="rounded-b-lg border-t border-line bg-panel-2 px-5 py-4 text-center text-[13px] text-muted sm:px-8">
                    {if creating {
                        <>Already have an account? <Link to={"/login" + suffix} className="font-medium text-accent hover:underline">Log in</Link></>
                    } else {
                        <>{"New to " + PRODUCT + "? "}<Link to={"/signup" + suffix} className="font-medium text-accent hover:underline">Create account</Link></>
                    }}
                </div>
            </div>
            <p className="mt-6 max-w-[420px] text-center text-[12px] leading-[18px] text-faint">{DISCLAIMER}</p>
        </main>
    </div>
}

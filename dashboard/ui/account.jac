"""Signing in, for any page that has something for an account. The field takes a username as
well as an email, since the team's admin account is named `admin`."""
import from "@jac/runtime" { SignupResult, jacLogin, jacSignup }
import from dashboard.ui.parts { TAP_BUTTON, TAP_INPUT }

"""Calls `done` once the reader is signed in."""
def:pub SignInForm(heading: str, blurb: str, done: Callable[[], None]) -> JsxElement {
    has identity: str = "",
        password: str = "",
        signup: bool = False,
        busy: bool = False,
        error: str = "";

    async def submit(e: FormEvent) {
        e.preventDefault();
        busy = True;
        error = "";
        result: SignupResult | None = None;
        ok: bool = False;
        try {
            if signup {
                result = await jacSignup(identity, password);
                if not result.success {
                    error = "Account creation failed. Check your details or sign in instead.";
                    return;
                }
            }
            ok = await jacLogin(identity, password);
            if ok {
                password = "";
                done();
            } else {
                error = "Sign-in failed. Check your details and try again.";
            }
        } except Exception {
            error = "Unable to sign in. Please try again.";
        } finally {
            busy = False;
        }
    }

    <div className="flex flex-col gap-3">
        <div>
            <h2 className="text-[15px] font-medium">{"Create an account" if signup else heading}</h2>
            <p className="mt-1 text-[13px] text-muted">{blurb}</p>
        </div>
        {if error { <p className="rounded-md border border-down/35 bg-down/10 px-3 py-2 text-[13px] text-down" role="alert">{error}</p> }}
        <form onSubmit={submit} className="flex flex-col gap-2.5">
            <label className="flex flex-col gap-1 text-[12px] text-muted">
                Email or username
                <input type="text" required={True} autoComplete="username" autoCapitalize="none" spellCheck={False} value={identity} onChange={lambda (e: ChangeEvent) { identity = e.target.value; }} className={TAP_INPUT}/>
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-muted">
                Password
                <input type="password" required={True} minLength={8} autoComplete={"new-password" if signup else "current-password"} value={password} onChange={lambda (e: ChangeEvent) { password = e.target.value; }} className={TAP_INPUT}/>
            </label>
            <button type="submit" disabled={busy} className={TAP_BUTTON}>{"Please wait…" if busy else ("Create account" if signup else "Sign in")}</button>
        </form>
        <button type="button" disabled={busy} onClick={lambda { signup = not signup; error = ""; }} className="press min-h-11 self-start text-[13px] text-accent hover:underline">
            {"Already have an account? Sign in" if signup else "New here? Create an account"}
        </button>
    </div>
}

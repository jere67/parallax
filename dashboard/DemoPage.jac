"""The demo account's door: /demo signs in to it, with no password, and opens the app. A link
anyone can share, so a visitor without API keys can look around first."""
import from "@jac/runtime" { Link, jacLogout, useNavigate }
import from dashboard.ui.brand { DISCLAIMER, ThemeSwitch, Wordmark }
import from dashboard.ui.demo { sign_in_demo }

def:pub DemoPage -> JsxElement {
    has problem: str = "",
        busy: bool = True;

    nav = useNavigate();

    async def open {
        busy = True;
        problem = "";
        # Whoever was signed in here leaves first, so the demo never shows under their name.
        jacLogout();
        found = await sign_in_demo();
        if not found {
            nav("/app", {"replace": True});
            return;
        }
        problem = found;
        busy = False;
    }

    async can with entry {
        await open();
    }

    <div className="flex min-h-dvh flex-col pt-[env(safe-area-inset-top)]">
        <header className="mx-auto flex h-16 w-full max-w-[1200px] items-center justify-between px-4 sm:px-6 lg:px-8">
            <Wordmark/>
            <ThemeSwitch/>
        </header>
        <main className="flex flex-1 flex-col items-center px-4 pb-10 pt-10 sm:pt-16">
            <div className="w-full max-w-[420px] rounded-lg border border-line bg-panel px-5 pb-6 pt-7 shadow-overlay sm:px-8 sm:pt-8">
                <h1 className="text-[22px] font-medium leading-7 text-text">The demo account</h1>
                {if busy {
                    <p className="mt-1.5 text-[13px] leading-5 text-muted" role="status">Opening it now…</p>
                } else {
                    <>
                        <p className="mt-4 rounded-md border border-down/35 bg-down/10 px-3 py-2 text-[13px] leading-5 text-down" role="alert">{problem}</p>
                        <div className="mt-5 flex flex-wrap items-center gap-3">
                            <button type="button" onClick={open} className="press min-h-11 rounded-md bg-accent px-4 text-[14px] font-medium text-bg">Try again</button>
                            <Link to="/" className="press inline-flex min-h-11 items-center rounded-md px-3 text-[14px] font-medium text-text hover:bg-hover">Back to the front page</Link>
                        </div>
                    </>
                }}
            </div>
            <p className="mt-6 max-w-[420px] text-center text-[12px] leading-[18px] text-faint">{DISCLAIMER}</p>
        </main>
    </div>
}

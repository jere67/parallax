"""Installing the dashboard on a phone, and saying so when it is offline. The service worker
(assets/sw.js) keeps the app's shell for a phone with no signal; its data never comes from a
cache, so a figure on screen is never older than the page says."""
import from "react" { useEffect }

glob WORKER_URL: str = "/sw.js";
glob DISMISSED_KEY: str = "trading-agent-install-dismissed";

"""Register the service worker, once, after the page has loaded, and never let a failure reach
the reader: the dashboard works the same without one."""
def:pub register_worker {
    useEffect(lambda {
        nav: any = navigator;
        if nav.serviceWorker {
            nav.serviceWorker.register(WORKER_URL).catch(lambda (_e: any) { None; });
        }
    }, []);
}

"""A band under the top bar while the browser reports no connection."""
def:pub OfflineBanner -> JsxElement {
    has online: bool = navigator.onLine;

    useEffect(lambda {
        def went_online { online = True; }
        def went_offline { online = False; }
        window.addEventListener("online", went_online);
        window.addEventListener("offline", went_offline);
        return lambda {
            window.removeEventListener("online", went_online);
            window.removeEventListener("offline", went_offline);
        };
    }, []);

    if online {
        return <></>;
    }
    <div className="border-b border-warn/25 bg-warn/10" role="status">
        <p className="mx-auto max-w-[1200px] px-4 py-2 text-[12px] text-warn sm:px-6 lg:px-8">
            <span className="font-semibold">You are offline.</span>
            {" "}What is on screen may be out of date, and nothing can be saved until you reconnect.
        </p>
    </div>
}

def is_ios -> bool {
    agent = navigator.userAgent;
    return "iPhone" in agent or "iPad" in agent or "iPod" in agent;
}

def is_installed -> bool {
    win: any = window;
    nav: any = navigator;
    return bool(win.matchMedia("(display-mode: standalone)").matches) or nav.standalone == True;
}

def remembered_dismissal -> bool {
    try {
        return localStorage.getItem(DISMISSED_KEY) == "1";
    } except Exception {
        return False;
    }
}

"""A quiet line on a phone: a button where the browser offers an install, and the steps on iOS,
where it does not."""
def:pub InstallHint -> JsxElement {
    has offer: any = None,
        dismissed: bool = remembered_dismissal() or is_installed();

    useEffect(lambda {
        def offered(e: any) {
            e.preventDefault();
            offer = e;
        }
        window.addEventListener("beforeinstallprompt", offered);
        return lambda { window.removeEventListener("beforeinstallprompt", offered); };
    }, []);

    def dismiss {
        dismissed = True;
        try {
            localStorage.setItem(DISMISSED_KEY, "1");
        } except Exception { }
    }

    async def install {
        if offer is not None {
            await offer.prompt();
            offer = None;
            dismiss();
        }
    }

    if dismissed or (offer is None and not is_ios()) {
        return <></>;
    }
    <p className="mt-2 flex flex-wrap items-center gap-x-3 md:hidden" data-testid="install-hint">
        {<button type="button" onClick={install} className="press min-h-11 font-medium text-accent">Install the app</button> if offer is not None else <span>On iPhone, tap Share, then Add to Home Screen, to install the app.</span>}
        <button type="button" onClick={dismiss} className="press min-h-11 text-faint hover:text-text">Not now</button>
    </p>
}

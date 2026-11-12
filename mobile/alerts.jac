"""Tells the reader when a morning run finishes - WEB variant, through the browser's
notifications when allowed. `alerts.native.jac` uses the phone's notifications; both export the
same names. Expo Go cannot receive remote pushes without an Expo account, so the app checks for
a new run while it is open and whenever it comes back to the foreground, and raises a local
notification itself."""

async def:pub allow_alerts -> bool {
    notices: any = window.Notification;  # jac:ignore[E1030]
    if not notices {
        return False;
    }
    if notices.permission == "granted" {
        return True;
    }
    asked = await notices.requestPermission();
    return asked == "granted";
}

async def:pub alert(title: str, body: str) {
    notices: any = window.Notification;  # jac:ignore[E1030]
    if notices and notices.permission == "granted" {
        new(notices, title, {"body": body});  # jac:ignore[E1053]
    }
}

"""Calls `back` each time the page becomes visible again; returns the function that stops it."""
def:pub on_foreground(back: Callable[[], None]) -> any {
    page: any = document;  # jac:ignore[E1032]
    handler = lambda {
        if page.visibilityState == "visible" {
            back();
        }
    };
    page.addEventListener("visibilitychange", handler);
    return lambda { page.removeEventListener("visibilitychange", handler); };
}

"""Tells the reader when a morning run finishes - NATIVE variant, through local notifications
(expo-notifications), which Expo Go supports without an Expo account. Same names as
`alerts.jac`."""

import from "expo-notifications" { getPermissionsAsync, requestPermissionsAsync, scheduleNotificationAsync, setNotificationHandler }
import from "react-native" { AppState }

async def:pub allow_alerts -> bool {
    # Show the banner even while Parallax is the app on screen.
    setNotificationHandler({
        "handleNotification": lambda {
            return Promise.resolve({"shouldShowBanner": True, "shouldShowList": True, "shouldPlaySound": True, "shouldSetBadge": False});
        }
    });
    current = await getPermissionsAsync();
    if current.granted {
        return True;
    }
    asked = await requestPermissionsAsync();
    return bool(asked.granted);
}

async def:pub alert(title: str, body: str) {
    try {
        await scheduleNotificationAsync({"content": {"title": title, "body": body}, "trigger": None});
    } except Exception { }
}

"""Calls `back` each time the app returns to the foreground; returns the function that stops it."""
def:pub on_foreground(back: Callable[[], None]) -> any {
    subscription = AppState.addEventListener("change", lambda (state: str) {
        if state == "active" {
            back();
        }
    });
    return lambda { subscription.remove(); };
}

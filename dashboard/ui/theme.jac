"""The reader's color theme. It follows the system until the reader picks light or dark, which
is saved in this browser and set as data-theme on <html> (dashboard/theme.css)."""

glob THEME_KEY: str = "trading-agent-theme";
glob:pub THEME_EVENT: str = "trading-agent-theme";

def:pub saved_theme -> str {
    try {
        return localStorage.getItem(THEME_KEY) or "";
    } except Exception {
        return "";
    }
}

"""Set the saved theme on <html>; called once while the app first renders, before paint."""
def:pub restore_theme {
    choice = saved_theme();
    if choice == "light" or choice == "dark" {
        document.documentElement.setAttribute("data-theme", choice);
    }
}

def:pub is_dark -> bool {
    choice = document.documentElement.getAttribute("data-theme");
    if choice {
        return choice == "dark";
    }
    return window.matchMedia("(prefers-color-scheme: dark)").matches;  # jac:ignore[E1030,E1002]
}

"""Pick light or dark, save it, and tell the charts to repaint. Transitions are off for the
swap, so every color changes in one frame instead of each fading on its own."""
def:pub set_theme(choice: str) {
    still = document.createElement("style");
    still.append(document.createTextNode("*,*::before,*::after{transition:none !important}"));  # jac:ignore[E1030]
    document.head.append(still);  # jac:ignore[E1030]
    document.documentElement.setAttribute("data-theme", choice);
    # Reading a layout value makes the browser apply the new colors now, under the override.
    document.body.offsetHeight;
    window.requestAnimationFrame(
        lambda {
            window.requestAnimationFrame(
                lambda {
                    still.remove();  # jac:ignore[E1030]
                }
            );
        }
    );
    try {
        localStorage.setItem(THEME_KEY, choice);
    } except Exception { }
    window.dispatchEvent(new(CustomEvent, THEME_EVENT));  # jac:ignore[E1053]
}

"""A design token's current value, such as css_var("--up")."""
def:pub css_var(name: str) -> str {
    return str(window.getComputedStyle(document.documentElement).getPropertyValue(name)).strip();  # jac:ignore[E1030]
}

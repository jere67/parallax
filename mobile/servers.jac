"""Where the Parallax servers are - WEB variant: on the machine serving this page.
`servers.native.jac` reads them from the Expo dev server; both export the same names."""

"""The host that served this app, or "" when it cannot tell."""
def:pub dev_host -> str {
    try {
        return str(window.location.hostname or "");  # jac:ignore[E1032]
    } except Exception {
        return "";
    }
}

"""Server addresses given at start. The web preview has no app config, so it has none."""
def:pub given_servers -> dict[str, str] {
    return {};
}

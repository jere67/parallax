"""Where the Parallax servers are - NATIVE variant: read from the app's config, which the Expo
dev server sends with the app. Same names as `servers.jac`."""

import from "expo-constants" { default as Constants }

"""The dev server's host (an address on the Wi-Fi, or a tunnel's name), or "" in a build."""
def:pub dev_host -> str {
    try {
        uri = str(Constants.expoConfig.hostUri or "");
        return uri.split(":")[0];
    } except Exception {
        return "";
    }
}

"""Server addresses given when the dev server started (scripts/tunnel.sh sets them through
expo/app.config.js), by name: "live" and "demo". Empty when none were given."""
def:pub given_servers -> dict[str, str] {
    try {
        given = Constants.expoConfig.extra.parallaxServers;
        if not given {
            return {};
        }
        return {"live": str(given["live"] or ""), "demo": str(given["demo"] or "")};
    } except Exception {
        return {};
    }
}

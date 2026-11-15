"""Signing in to the demo account, which has no password (accounts/demo.jac): the server hands out
its token, and the runtime keeps it as it would after a log-in."""
import from "@jac/runtime" { jacSetToken }
import from dashboard.ui.rpc { open_demo }

# The demo account's username, and the name of the portfolio it shows (accounts/store.jac).
glob:pub DEMO_ACCOUNT: str = "demo";

"""Sign in as the demo account. Returns "" when signed in, or why not, in words for the reader."""
async def:pub sign_in_demo -> str {
    try {
        found: any = await open_demo();
        if found and found.token {
            jacSetToken(found.token);
            return "";
        }
        return (found.message if found else "") or "The demo account is not available right now. Try again in a minute.";
    } except Exception {
        return "The server could not be reached. Try again in a moment.";
    }
}

"""Talks to a Parallax server over HTTP, the same endpoints the web dashboard calls.

The phone picks its server at sign-in (the team's live server, a demo server, or any address),
so calls carry that address rather than one fixed at build time. Every call returns a `Reply`
instead of raising, so a screen always has something to say: the data, that the session ended,
or why the server could not be reached. The app only reads; nothing here can place an order or
start a run."""

glob TIMEOUT_MS: int = 15000;

obj Reply {
    has ok: bool = False,
        data: any = None,
        problem: str = "",
        signed_out: bool = False;
}

"""True for an address reached over plain HTTP: this machine, a `.local` name, or a bare IP
address (a laptop on the Wi-Fi or a hotspot; no certificate is issued for a bare IP)."""
def:pub is_local_host(host: str) -> bool {
    h = host.lower().split("/")[0].split(":")[0];
    if h == "localhost" or h.endswith(".local") or host.startswith("[") {
        return True;
    }
    parts = h.split(".");
    if len(parts) != 4 {
        return False;
    }
    for part in parts {
        if len(part) == 0 or len(part) > 3 {
            return False;
        }
        for ch in part {
            if ch not in "0123456789" {
                return False;
            }
        }
    }
    return True;
}

"""A server address as typed, made into a base URL: `parallax.jaseci.app` becomes
`https://parallax.jaseci.app`, `192.168.1.20:8100` becomes `http://192.168.1.20:8100`."""
def:pub clean_server(text: str) -> str {
    t = text.strip();
    if not t {
        return "";
    }
    if not (t.startswith("http://") or t.startswith("https://")) {
        t = ("http://" if is_local_host(t) else "https://") + t;
    }
    while t.endswith("/") {
        t = t[:-1];
    }
    return t;
}

"""The address without its scheme, for showing on screen."""
def:pub server_label(server: str) -> str {
    return server.replace("https://", "").replace("http://", "");
}

async def post(server: str, path: str, body: dict[str, object], token: str = "") -> Reply {
    headers = {"Content-Type": "application/json"};
    if token {
        headers = {**headers, "Authorization": f"Bearer {token}"};
    }
    controller = new(AbortController);  # jac:ignore[W2001]
    timer = setTimeout(lambda { controller.abort(); }, TIMEOUT_MS);
    try {
        response = await fetch(server + path, {"method": "POST", "headers": headers, "body": JSON.stringify(body), "signal": controller.signal});
    } except Exception {
        clearTimeout(timer);
        return Reply(problem=f"Could not reach {server_label(server)}. Check the address and that the server is running.");
    }
    clearTimeout(timer);
    text = await response.text();
    payload: any = None;
    try {
        payload = JSON.parse(text);
    } except Exception {
        payload = None;
    }
    if response.status == 401 or response.status == 403 {
        return Reply(signed_out=True, problem="Your session ended. Sign in again.");
    }
    if not response.ok or not payload {
        return Reply(problem=f"The server answered {response.status}. Try again in a moment.");
    }
    if payload["ok"] == False {
        return Reply(problem=str(payload["error"] or "The server refused the request."));
    }
    return Reply(ok=True, data=payload["data"]);
}

"""Sign in with a Parallax username and password; the reply's data is the session token."""
async def:pub sign_in(server: str, username: str, password: str) -> Reply {
    reply = await post(
        server,
        "/user/login",
        {"identity": {"type": "username", "value": username.strip()}, "credential": {"type": "password", "password": password}}
    );
    if reply.signed_out {
        return Reply(problem="That username and password do not match an account on this server.");
    }
    if not reply.ok {
        return reply;
    }
    token = reply.data["token"] if reply.data else "";
    if not token {
        return Reply(problem="The server did not return a session. Try again.");
    }
    return Reply(ok=True, data=token);
}

"""Call one of the dashboard's endpoints; the reply's data is its result."""
async def:pub call(server: str, token: str, name: str, args: dict[str, str] | None = None) -> Reply {
    reply = await post(server, f"/function/{name}", args or {}, token);
    if not reply.ok {
        return reply;
    }
    return Reply(ok=True, data=reply.data["result"] if reply.data else None);
}

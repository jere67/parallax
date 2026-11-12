"""Local stand-ins for the paper account, OpenRouter's key check, and Finnhub, for testing what a
user's keys do. Each answers according to the key it is sent, and records which keys it saw, so a
test can prove whose keys a piece of work used."""
import json;
import threading;
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
import from urllib.parse { parse_qs, urlsplit }

glob GOOD_ALPACA: str = "PKGOODKEY0001";
glob GOOD_SECRET: str = "good-secret-value-1";
# A second user's own paper account; it shares GOOD_SECRET for brevity.
glob OTHER_ALPACA: str = "PKGOODKEY0002";
glob ACCOUNT_NUMBERS: dict[str, str] = {GOOD_ALPACA: "PA3TEST7890", OTHER_ALPACA: "PA3TEST4321"};
glob LIVE_ALPACA: str = "AKLIVEKEY0001";
glob GOOD_OPENROUTER: str = "sk-or-good-key-0001";
glob SMALL_OPENROUTER: str = "sk-or-small-key-002";
glob GOOD_FINNHUB: str = "finnhub-good-key-01";

obj FakeProviders {
    has alpaca_seen: list[str] = [],
        alpaca_paths: list[tuple[str, str]] = [],
        positions: list[dict[str, str]] = [],
        down: bool = False;
    has _server: ThreadingHTTPServer | None = None;

    def start -> str {
        server = ThreadingHTTPServer(("127.0.0.1", 0), ProviderHandler);
        setattr(server, "fake", self);
        self._server = server;
        threading.Thread(target=server.serve_forever, daemon=True).start();
        return f"http://127.0.0.1:{server.server_address[1]}";
    }

    def stop {
        if self._server {
            self._server.shutdown();
            self._server.server_close();
        }
    }
}

class ProviderHandler(BaseHTTPRequestHandler) {
    def log_message(self: ProviderHandler, *_args: object) { }

    def reply(self: ProviderHandler, status: int, body: object) {
        data = json.dumps(body).encode();
        self.send_response(status);
        self.send_header("Content-Type", "application/json");
        self.send_header("Content-Length", str(len(data)));
        self.end_headers();
        self.wfile.write(data);
    }

    def do_GET(self: ProviderHandler) {
        fake: FakeProviders = getattr(self.server, "fake");
        path = self.path.split("?")[0];
        if fake.down {
            self.reply(503, {"message": "down"});
        } elif path.startswith("/v2/") {
            self.alpaca(fake, path);
        } elif path.endswith("/key") {
            self.openrouter();
        } elif path.endswith("/quote") {
            good = self.headers.get("X-Finnhub-Token", "") == GOOD_FINNHUB;
            self.reply(200 if good else 401, {"c": 500.0} if good else {"error": "Invalid API key"});
        } else {
            self.reply(404, {"message": "not found"});
        }
    }

    def alpaca(self: ProviderHandler, fake: FakeProviders, path: str) {
        key = self.headers.get("APCA-API-KEY-ID", "");
        fake.alpaca_seen.append(key);
        fake.alpaca_paths.append((key, path));
        if key not in ACCOUNT_NUMBERS or self.headers.get("APCA-API-SECRET-KEY", "") != GOOD_SECRET {
            self.reply(403, {"message": "forbidden."});
        } elif path == "/v2/account" {
            self.reply(200, {"account_number": ACCOUNT_NUMBERS[key], "status": "ACTIVE", "equity": "100000", "cash": "100000", "buying_power": "200000", "last_equity": "100000", "trading_blocked": False, "account_blocked": False});
        } elif path == "/v2/positions" {
            self.reply(200, fake.positions);
        } elif path == "/v2/orders" {
            self.reply(200, []);
        } elif path == "/v2/calendar" {
            day = parse_qs(urlsplit(self.path).query).get("start", [""])[0];
            self.reply(200, [{"date": day, "open": "09:30", "close": "16:00"}]);
        } else {
            self.reply(404, {"message": "not found"});
        }
    }

    def openrouter(self: ProviderHandler) {
        key = self.headers.get("Authorization", "").removeprefix("Bearer ");
        if key == GOOD_OPENROUTER {
            self.reply(200, {"data": {"free_model_daily_requests": {"used": 0, "limit": 1000, "remaining": 1000}}});
        } elif key == SMALL_OPENROUTER {
            self.reply(200, {"data": {"free_model_daily_requests": {"used": 0, "limit": 50, "remaining": 50}}});
        } else {
            self.reply(401, {"error": {"message": "No auth credentials found"}});
        }
    }
}

"""A stateful stand-in for Alpaca's paper trading and market data APIs, for executor and job
tests (TDD §14, testing).

Point ALPACA_BASE_URL and ALPACA_DATA_URL at `start()`'s URL. The fake keeps an account,
positions, and orders, and enforces the order rules the order-rule spike observed on the
paper account (docs/spikes/2026-10-21-alpaca-order-rules.md):

- a new order is rejected while an order on the opposite side of the same symbol is working
  (wash-trade protection), with Alpaca's 403;
- a sell may not exceed the shares not already reserved by working sell orders, stops
  included (403 "insufficient qty available");
- a reused client order ID is refused with 422, and `GET /v2/orders:by_client_order_id`
  finds the first order;
- a canceled or filled order cannot be canceled again (422).

Nothing fills on its own unless `auto_fill` is set, which fills a marketable limit or market
order in full when it arrives: a test fills orders with `fill`, moves prices with `set_price`
(which fills any working sell stop at or above the new price), and ends a session with
`close_session`, which cancels unfilled DAY orders. `script` queues error responses, to
inject outages.
"""
import json;
import threading;
import uuid;
import from datetime { date, datetime, timedelta, timezone }
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
import from urllib.parse { parse_qsl, urlsplit }

glob WORKING: set[str] = {"new", "accepted", "partially_filled", "pending_cancel", "held"};

obj FakeOrder {
    has id: str,
        client_order_id: str,
        symbol: str,
        side: str,
        order_type: str,
        time_in_force: str,
        qty: int,
        submitted_at: str;
    has limit_price: float | None = None,
        stop_price: float | None = None,
        filled_qty: int = 0,
        filled_avg_price: float | None = None,
        status: str = "new",
        filled_at: str = "",
        canceled_at: str = "";

    def working -> bool {
        return self.status in WORKING;
    }

    def to_json -> dict[str, str | int | float | None | list[str]] {
        return {
            "id": self.id,
            "client_order_id": self.client_order_id,
            "symbol": self.symbol,
            "side": self.side,
            "type": self.order_type,
            "order_type": self.order_type,
            "time_in_force": self.time_in_force,
            "qty": str(self.qty),
            "filled_qty": str(self.filled_qty),
            "filled_avg_price": None if self.filled_avg_price is None else f"{self.filled_avg_price:.4f}",
            "limit_price": None if self.limit_price is None else f"{self.limit_price:.2f}",
            "stop_price": None if self.stop_price is None else f"{self.stop_price:.2f}",
            "status": self.status,
            "order_class": "",
            "submitted_at": self.submitted_at,
            "filled_at": self.filled_at or None,
            "canceled_at": self.canceled_at or None,
            "legs": None
        };
    }
}

obj FakePosition {
    has symbol: str,
        qty: int,
        avg_entry_price: float;
}

"""One scripted reply: the next request whose method matches and whose path starts with
`path` gets `status` and `body` instead of its normal answer."""
obj Scripted {
    has method: str,
        path: str,
        status: int,
        body: str;
}

obj FakeBroker {
    has cash: float = 100000.0,
        account_number: str = "PA0FAKE000",
        now: str = "2026-10-21T13:45:00+00:00",
        is_open: bool = True,
        holidays: set[str] = set(),
        early_closes: set[str] = set(),
        untradable: set[str] = set(),
        auto_fill: bool = False;
    has prices: dict[str, float] = {},
        trade_times: dict[str, str] = {},
        bars: dict[str, list[dict[str, str | float | int]]] = {},
        orders: list[FakeOrder] = [],
        positions: dict[str, FakePosition] = {},
        script: list[Scripted] = [],
        requests: list[str] = [],
        rejections: list[str] = [];
    has _server: ThreadingHTTPServer | None = None,
        _lock: threading.RLock | None = None;

    """Serve on a free local port and return its URL, for ALPACA_BASE_URL and ALPACA_DATA_URL."""
    def start -> str {
        self._lock = threading.RLock();
        server = ThreadingHTTPServer(("127.0.0.1", 0), _BrokerHandler);
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

    def equity -> float {
        return self.cash + sum(p.qty * self.prices.get(p.symbol, p.avg_entry_price) for p in self.positions.values());
    }

    """Set the last trade price for `symbol` and fill any working sell stop it reaches."""
    def set_price(symbol: str, price: float) {
        with self._guard() {
            self.prices[symbol] = price;
            self.trade_times[symbol] = self.now;
            for o in list(self.orders) {
                if o.working() and o.symbol == symbol and o.order_type == "stop" and o.stop_price is not None {
                    if (o.side == "sell" and price <= o.stop_price) or (o.side == "buy" and price >= o.stop_price) {
                        self._fill(o, o.qty - o.filled_qty, price);
                    }
                }
            }
        }
    }

    """Fill `qty` more shares of the order with this id or client order ID (all that is left
    when `qty` is 0) at `price` (its limit, or the last price, when 0)."""
    def fill(order_ref: str, qty: int = 0, price: float = 0.0) -> FakeOrder {
        with self._guard() {
            o = self.find(order_ref);
            if o is None or not o.working() {
                raise ValueError(f"no working order {order_ref}");
            }
            left = o.qty - o.filled_qty;
            at = price or o.limit_price or o.stop_price or self.prices.get(o.symbol, 0.0);
            self._fill(o, min(qty or left, left), at);
            return o;
        }
    }

    """End the session: unfilled DAY orders are canceled, as Alpaca does after the close."""
    def close_session {
        with self._guard() {
            for o in self.orders {
                if o.working() and o.time_in_force == "day" {
                    o.status = "canceled";
                    o.canceled_at = self.now;
                }
            }
        }
    }

    def find(order_ref: str) -> FakeOrder | None {
        for o in self.orders {
            if o.id == order_ref or o.client_order_id == order_ref {
                return o;
            }
        }
        return None;
    }

    def working_orders(symbol: str = "") -> list[FakeOrder] {
        return [o for o in self.orders if o.working() and (not symbol or o.symbol == symbol)];
    }

    def _guard -> threading.RLock {
        if self._lock is None {
            self._lock = threading.RLock();
        }
        return self._lock;
    }

    def _fill(o: FakeOrder, qty: int, price: float) {
        if qty <= 0 {
            return;
        }
        before = o.filled_qty;
        o.filled_qty += qty;
        o.filled_avg_price = ((o.filled_avg_price or 0.0) * before + price * qty) / o.filled_qty;
        o.status = "filled" if o.filled_qty == o.qty else "partially_filled";
        o.filled_at = self.now;
        held = self.positions.get(o.symbol);
        if o.side == "buy" {
            self.cash -= qty * price;
            if held is None {
                self.positions[o.symbol] = FakePosition(symbol=o.symbol, qty=qty, avg_entry_price=price);
            } else {
                held.avg_entry_price = (held.avg_entry_price * held.qty + price * qty) / (held.qty + qty);
                held.qty += qty;
            }
        } else {
            self.cash += qty * price;
            if held is not None {
                held.qty -= qty;
                if held.qty <= 0 {
                    del self.positions[o.symbol];
                }
            }
        }
        self.prices.setdefault(o.symbol, price);
    }

    """Answer one request with (status, body)."""
    def answer(method: str, path: str, params: dict[str, str], payload: dict[str, str]) -> tuple[int, str] {
        with self._guard() {
            self.requests.append(f"{method} {path}");
            for (i, s) in enumerate(self.script) {
                if s.method == method and path.startswith(s.path) {
                    self.script.pop(i);
                    return (s.status, s.body);
                }
            }
            if method == "GET" and path == "/v2/account" {
                return (200, json.dumps(self._account()));
            }
            if method == "GET" and path == "/v2/clock" {
                return (200, json.dumps({"is_open": self.is_open, "timestamp": self.now, "next_open": self.now, "next_close": self.now}));
            }
            if method == "GET" and path == "/v2/positions" {
                return (200, json.dumps([self._position(p) for p in self.positions.values()]));
            }
            if method == "GET" and path == "/v2/orders" {
                return (200, json.dumps([o.to_json() for o in self._listed(params)]));
            }
            if method == "GET" and path == "/v2/orders:by_client_order_id" {
                found = self.find(params.get("client_order_id", ""));
                return (200, json.dumps(found.to_json())) if found is not None else (404, _error("order not found"));
            }
            if method == "GET" and path.startswith("/v2/orders/") {
                found = self.find(path.rsplit("/", 1)[-1]);
                return (200, json.dumps(found.to_json())) if found is not None else (404, _error("order not found"));
            }
            if method == "POST" and path == "/v2/orders" {
                return self._submit(payload);
            }
            if method == "DELETE" and path.startswith("/v2/orders/") {
                found = self.find(path.rsplit("/", 1)[-1]);
                if found is None {
                    return (404, _error("order not found"));
                }
                if not found.working() {
                    return (422, _error(f"order is already in \"{found.status}\" state"));
                }
                found.status = "canceled";
                found.canceled_at = self.now;
                return (204, "");
            }
            if method == "GET" and path == "/v2/calendar" {
                return (200, json.dumps(self._calendar(params.get("start", ""), params.get("end", ""))));
            }
            if method == "GET" and path == "/v2/assets" {
                symbols = sorted(set(self.prices) | self.untradable);
                return (200, json.dumps([{"symbol": s, "name": s, "exchange": "NYSE", "tradable": s not in self.untradable, "fractionable": True, "shortable": True, "easy_to_borrow": True, "status": "active"} for s in symbols]));
            }
            if method == "GET" and path == "/v2/stocks/trades/latest" {
                wanted = [s for s in params.get("symbols", "").split(",") if s];
                return (200, json.dumps({"trades": {s: {"p": self.prices[s], "s": 100, "t": self.trade_times.get(s, self.now), "x": "V"} for s in wanted if s in self.prices}}));
            }
            if method == "GET" and path == "/v2/stocks/bars" {
                return (200, json.dumps(self._bars(params)));
            }
            return (404, _error(f"the fake has no route for {method} {path}"));
        }
    }

    def _submit(payload: dict[str, str]) -> tuple[int, str] {
        symbol = str(payload.get("symbol", ""));
        side = str(payload.get("side", ""));
        qty = int(float(str(payload.get("qty", "0"))));
        cid = str(payload.get("client_order_id") or uuid.uuid4());
        kind = str(payload.get("type", ""));
        if "order_class" in payload {
            return self._reject(422, f"{symbol}: the fake broker does not support order classes");
        }
        if any(o.client_order_id == cid for o in self.orders) {
            return self._reject(422, "client_order_id must be unique");
        }
        if symbol in self.untradable {
            return self._reject(422, f"asset {symbol} is not tradable");
        }
        if qty <= 0 {
            return self._reject(422, "qty must be > 0");
        }
        opposite = "sell" if side == "buy" else "buy";
        if any(o.side == opposite for o in self.working_orders(symbol)) {
            return self._reject(403, "potential wash trade detected. use complex orders");
        }
        limit = float(str(payload["limit_price"])) if payload.get("limit_price") else None;
        stop = float(str(payload["stop_price"])) if payload.get("stop_price") else None;
        if side == "sell" {
            held = self.positions.get(symbol);
            reserved = sum(o.qty - o.filled_qty for o in self.working_orders(symbol) if o.side == "sell");
            available = (held.qty if held is not None else 0) - reserved;
            if qty > available {
                return self._reject(403, f"insufficient qty available for order (requested: {qty}, available: {max(0, available)})");
            }
        } else {
            price = limit or stop or self.prices.get(symbol, 0.0);
            if qty * price > self.cash {
                return self._reject(403, "insufficient buying power");
            }
        }
        o = FakeOrder(
            id=str(uuid.uuid4()),
            client_order_id=cid,
            symbol=symbol,
            side=side,
            order_type=kind,
            time_in_force=str(payload.get("time_in_force", "day")),
            qty=qty,
            submitted_at=self.now,
            limit_price=limit,
            stop_price=stop,
            status="accepted" if kind == "stop" else "new"
        );
        self.orders.append(o);
        last = self.prices.get(symbol);
        if self.auto_fill and last is not None and (kind == "market" or (kind == "limit" and limit is not None and (limit >= last if side == "buy" else limit <= last))) {
            self._fill(o, qty, last);
        }
        return (200, json.dumps(o.to_json()));
    }

    def _reject(status: int, message: str) -> tuple[int, str] {
        self.rejections.append(message);
        return (status, _error(message));
    }

    def _listed(params: dict[str, str]) -> list[FakeOrder] {
        status = params.get("status", "open");
        symbols = {s for s in params.get("symbols", "").split(",") if s};
        found = [
            o
            for o in reversed(self.orders)
            if (not symbols or o.symbol in symbols) and (status == "all" or (status == "open") == o.working())
        ];
        return found[:int(params.get("limit", "500"))];
    }

    def _account -> dict[str, str | bool] {
        return {
            "account_number": self.account_number,
            "status": "ACTIVE",
            "equity": f"{self.equity():.2f}",
            "cash": f"{self.cash:.2f}",
            "buying_power": f"{self.cash:.2f}",
            "last_equity": f"{self.equity():.2f}",
            "trading_blocked": False,
            "account_blocked": False
        };
    }

    def _position(p: FakePosition) -> dict[str, str] {
        price = self.prices.get(p.symbol, p.avg_entry_price);
        reserved = sum(o.qty - o.filled_qty for o in self.working_orders(p.symbol) if o.side == "sell");
        return {
            "symbol": p.symbol,
            "qty": str(p.qty),
            "qty_available": str(p.qty - reserved),
            "avg_entry_price": f"{p.avg_entry_price:.4f}",
            "current_price": f"{price:.4f}",
            "market_value": f"{p.qty * price:.2f}",
            "side": "long"
        };
    }

    def _calendar(start: str, end: str) -> list[dict[str, str]] {
        days: list[dict[str, str]] = [];
        day = date.fromisoformat(start[:10]);
        last = date.fromisoformat(end[:10]);
        while day <= last {
            text = day.isoformat();
            if day.weekday() < 5 and text not in self.holidays {
                days.append({"date": text, "open": "09:30", "close": "13:00" if text in self.early_closes else "16:00"});
            }
            day += timedelta(days=1);
        }
        return days;
    }

    def _bars(params: dict[str, str]) -> dict[str, dict[str, list[dict[str, str | float | int]]] | None] {
        wanted = [s for s in params.get("symbols", "").split(",") if s];
        start = params.get("start", "")[:10];
        end = params.get("end", "")[:10];
        found: dict[str, list[dict[str, str | float | int]]] = {};
        for s in wanted {
            rows = [b for b in self.bars.get(s, []) if start <= str(b["t"])[:10] <= end];
            if rows {
                found[s] = rows;
            }
        }
        return {"bars": found, "next_page_token": None};
    }
}

"""A daily bar row as Alpaca returns it, for `FakeBroker.bars`."""
def bar_row(day: str, close: float, high: float = 0.0, low: float = 0.0, volume: float = 1000000.0, open_price: float = 0.0) -> dict[str, str | float | int] {
    return {"t": f"{day}T04:00:00Z", "o": open_price or close, "h": high or close, "l": low or close, "c": close, "v": volume, "n": 1000, "vw": close};
}

def _error(message: str) -> str {
    return json.dumps({"code": 40010001, "message": message});
}

class _BrokerHandler(BaseHTTPRequestHandler) {
    def _serve(self: _BrokerHandler, method: str) {
        url = urlsplit(self.path);
        length = int(self.headers.get("Content-Length") or 0);
        payload: dict[str, str] = json.loads(self.rfile.read(length)) if length else {};
        fake = getattr(self.server, "fake") as FakeBroker;
        (status, body) = fake.answer(method, url.path, dict(parse_qsl(url.query)), payload);
        data = body.encode();
        self.send_response(status);
        self.send_header("Content-Type", "application/json");
        self.send_header("Content-Length", str(len(data)));
        self.end_headers();
        self.wfile.write(data);
    }

    def do_GET(self: _BrokerHandler) {
        self._serve("GET");
    }

    def do_POST(self: _BrokerHandler) {
        self._serve("POST");
    }

    def do_DELETE(self: _BrokerHandler) {
        self._serve("DELETE");
    }

    def log_message(self: _BrokerHandler, _fmt: str, *_args: object) {}
}

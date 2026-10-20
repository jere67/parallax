"""Alpaca's paper trading API, for the executor and reconciliation (TDD §8, execution on Alpaca).

Raw REST, like the collectors (research/alpaca.jac), with two differences: orders change
state, so nothing here is cached, and a request that changes something is retried only when
the order's `client_order_id` shows it did not happen.

- Paper only. The client refuses any base URL but Alpaca's paper host or a local test
  server, and `account` refuses an account whose number is not a paper account's (TDD §8:
  live endpoints are disabled in configuration and rejected in code).
- Every request shares the trading host's rate limit with the collectors' calendar and asset
  reads (research/sources.jac).
- Keys go in headers, which nothing here logs or stores.
- Prices go out rounded to the tick Alpaca accepts: a cent at $1 and above, a hundredth of a
  cent below, since a sub-penny limit or stop price is rejected.
"""
import json;
import math;
import os;
import time;
import from urllib.parse { urlsplit }
import httpx;
import from research.alpaca { alpaca_headers }
import from research.collector { TokenBucket, bucket_for }
import from research.sources { SOURCES }

glob PAPER_HOST: str = "paper-api.alpaca.markets";
# Hosts a test may point ALPACA_BASE_URL at, to reach a fake broker.
glob LOCAL_HOSTS: set[str] = {"127.0.0.1", "localhost"};
# Alpaca numbers paper accounts with this prefix.
glob PAPER_ACCOUNT_PREFIX: str = "PA";

# An order in one of these states can still fill or be canceled (Alpaca's order lifecycle).
glob WORKING_STATUSES: set[str] = {
    "new",
    "accepted",
    "pending_new",
    "accepted_for_bidding",
    "partially_filled",
    "done_for_day",
    "pending_cancel",
    "pending_replace",
    "held",
    "calculated",
    "stopped",
    "suspended"
};

"""The broker refused a request or kept failing. Status 0 means no HTTP response."""
obj BrokerError(Exception) {
    has path: str,
        status: int = 0,
        detail: str = "";

    override def __str__ -> str {
        return f"alpaca_trading: {self.detail or 'request failed'} (status {self.status}, {self.path})";
    }
}

"""The configuration points at something other than a paper account."""
obj NotPaper(BrokerError) {}

obj Account {
    has number: str,
        status: str,
        equity: float,
        cash: float,
        buying_power: float,
        last_equity: float,
        trading_blocked: bool;
}

obj BrokerPosition {
    has symbol: str,
        qty: int,
        qty_available: int,
        avg_entry_price: float,
        current_price: float,
        market_value: float;
}

"""One order as Alpaca reports it. Quantities are whole shares (TDD §8, position sizing)."""
obj BrokerOrder {
    has id: str,
        client_order_id: str,
        symbol: str,
        side: str,
        order_type: str,
        time_in_force: str,
        qty: int,
        filled_qty: int,
        status: str;
    has filled_avg_price: float | None = None,
        limit_price: float | None = None,
        stop_price: float | None = None,
        order_class: str = "",
        submitted_at: str = "",
        filled_at: str = "",
        canceled_at: str = "",
        legs: list[BrokerOrder] = [];

    def working -> bool {
        return self.status in WORKING_STATUSES;
    }
}

"""An order to submit. `stop_loss_price` attaches a stop to a one-triggers-other entry,
which only the order-rule spike uses (#13)."""
obj OrderRequest {
    has symbol: str,
        side: str,
        qty: int,
        order_type: str,
        time_in_force: str,
        client_order_id: str;
    has limit_price: float | None = None,
        stop_price: float | None = None,
        stop_loss_price: float | None = None;

    def postinit {
        if self.qty <= 0 {
            raise ValueError(f"{self.symbol}: an order needs a positive whole-share quantity, not {self.qty}");
        }
        if self.side not in ("buy", "sell") {
            raise ValueError(f"{self.symbol}: side must be buy or sell, not {self.side!r}");
        }
        if self.order_type == "limit" and self.limit_price is None {
            raise ValueError(f"{self.symbol}: a limit order needs a limit price");
        }
        if self.order_type == "stop" and self.stop_price is None {
            raise ValueError(f"{self.symbol}: a stop order needs a stop price");
        }
        if not self.client_order_id or len(self.client_order_id) > 128 {
            raise ValueError(f"{self.symbol}: client_order_id must be 1 to 128 characters");
        }
    }

    def body -> dict[str, str | dict[str, str]] {
        found: dict[str, str | dict[str, str]] = {
            "symbol": self.symbol,
            "side": self.side,
            "qty": str(self.qty),
            "type": self.order_type,
            "time_in_force": self.time_in_force,
            "client_order_id": self.client_order_id
        };
        if self.limit_price is not None {
            found["limit_price"] = tick_price(self.limit_price);
        }
        if self.stop_price is not None {
            found["stop_price"] = tick_price(self.stop_price);
        }
        if self.stop_loss_price is not None {
            found["order_class"] = "oto";
            found["stop_loss"] = {"stop_price": tick_price(self.stop_loss_price)};
        }
        return found;
    }
}

"""Whether the market is open now, and the next open and close, as Alpaca's clock reports."""
obj MarketClock {
    has is_open: bool,
        timestamp: str,
        next_open: str,
        next_close: str;
}

"""`price` as the decimal string Alpaca accepts: whole cents at $1 and above, and hundredths
of a cent below."""
def tick_price(price: float) -> str {
    if not math.isfinite(price) or price <= 0.0 {
        raise ValueError(f"a price must be positive, not {price}");
    }
    return f"{price:.2f}" if price >= 1.0 else f"{price:.4f}";
}

"""The trading API base URL: ALPACA_BASE_URL when set, else the paper host. Raises NotPaper
for anything that could reach a live account."""
def trading_base_url -> str {
    url = (os.environ.get(SOURCES["alpaca_trading"].base_url_env) or SOURCES["alpaca_trading"].base_url).rstrip("/");
    host = urlsplit(url).hostname or "";
    if host != PAPER_HOST and host not in LOCAL_HOSTS {
        raise NotPaper(path=url, detail=f"refusing {host or url!r}: only {PAPER_HOST} (or a local test server) may receive orders");
    }
    return url;
}

"""A client for one paper account. Construct it per job; it holds no state but its settings."""
obj Broker {
    has base_url: str = "",
        headers: dict[str, str] = {},
        bucket: TokenBucket | None = None,
        timeout_s: float = 15.0,
        max_retries: int = 2,
        backoff_s: float = 1.0;
    has _http: httpx.Client | None = None;

    def postinit {
        self.base_url = self.base_url.rstrip("/") if self.base_url else trading_base_url();
        host = urlsplit(self.base_url).hostname or "";
        if host != PAPER_HOST and host not in LOCAL_HOSTS {
            raise NotPaper(path=self.base_url, detail=f"refusing {host!r}: only {PAPER_HOST} may receive orders");
        }
        if not self.headers {
            self.headers = alpaca_headers();
        }
        if self.bucket is None {
            self.bucket = bucket_for(SOURCES["alpaca_trading"]);
        }
        self._http = httpx.Client(timeout=self.timeout_s);
    }

    """The account, after checking it is a paper account that may trade."""
    def account -> Account {
        row = self._object("GET", "/v2/account");
        found = Account(
            number=_text(row, "account_number"),
            status=_text(row, "status"),
            equity=_number(row, "equity"),
            cash=_number(row, "cash"),
            buying_power=_number(row, "buying_power"),
            last_equity=_number(row, "last_equity"),
            trading_blocked=bool(row.get("trading_blocked")) or bool(row.get("account_blocked"))
        );
        if not found.number.startswith(PAPER_ACCOUNT_PREFIX) {
            raise NotPaper(path="/v2/account", detail=f"account {found.number[:4]}... is not a paper account");
        }
        return found;
    }

    def clock -> MarketClock {
        row = self._object("GET", "/v2/clock");
        return MarketClock(
            is_open=bool(row.get("is_open")),
            timestamp=_text(row, "timestamp"),
            next_open=_text(row, "next_open"),
            next_close=_text(row, "next_close")
        );
    }

    """Every open position, by symbol."""
    def positions -> dict[str, BrokerPosition] {
        return {
            _text(row, "symbol"): BrokerPosition(
                symbol=_text(row, "symbol"),
                qty=_shares(row.get("qty")),
                qty_available=_shares(row.get("qty_available", row.get("qty"))),
                avg_entry_price=_number(row, "avg_entry_price"),
                current_price=_number(row, "current_price"),
                market_value=_number(row, "market_value")
            )
            for row in self._list("GET", "/v2/positions")
        };
    }

    """Orders in `status` ("open", "closed", or "all"), newest first, with legs nested."""
    def orders(status: str = "open", symbols: list[str] | None = None, after: str = "", limit: int = 500) -> list[BrokerOrder] {
        params: dict[str, str] = {"status": status, "limit": str(limit), "nested": "true", "direction": "desc"};
        if symbols {
            params["symbols"] = ",".join(sorted(set(symbols)));
        }
        if after {
            params["after"] = after;
        }
        return [_order(row) for row in self._list("GET", "/v2/orders", params=params)];
    }

    def order(order_id: str) -> BrokerOrder {
        return _order(self._object("GET", f"/v2/orders/{order_id}", params={"nested": "true"}));
    }

    """The order with this client order ID, or None when there is none."""
    def order_by_client_id(client_order_id: str) -> BrokerOrder | None {
        try {
            return _order(self._object("GET", "/v2/orders:by_client_order_id", params={"client_order_id": client_order_id}));
        } except BrokerError as e {
            if e.status == 404 {
                return None;
            }
            raise e;
        }
    }

    """Submit `request` once. The client order ID is looked up first, so a retried job gets the
    order it placed before rather than a second one, and Alpaca's 422 for a reused ID while
    the first order is open never arises (TDD §8, idempotency). A failed POST is retried only
    when the lookup shows the order was not created."""
    def submit(request: OrderRequest) -> BrokerOrder {
        existing = self.order_by_client_id(request.client_order_id);
        if existing is not None {
            return existing;
        }
        for attempt in range(self.max_retries + 1) {
            try {
                return _order(self._object("POST", "/v2/orders", payload=request.body(), retry=False));
            } except BrokerError as e {
                transient = e.status == 0 or e.status == 429 or e.status >= 500;
                if not transient and e.status != 422 {
                    raise e;
                }
                placed = self.order_by_client_id(request.client_order_id);
                if placed is not None {
                    return placed;
                }
                if not transient or attempt == self.max_retries {
                    raise e;
                }
                time.sleep(self.backoff_s * (2 ** attempt));
            }
        }
        raise BrokerError(path="/v2/orders", detail="unreachable");
    }

    """Ask Alpaca to cancel an order. True when the request was accepted; False when the order
    can no longer be canceled (it filled or was already canceled), which Alpaca answers 422."""
    def cancel(order_id: str) -> bool {
        try {
            self._request("DELETE", f"/v2/orders/{order_id}");
            return True;
        } except BrokerError as e {
            if e.status == 422 {
                return False;
            }
            raise e;
        }
    }

    """Cancel an order and wait until Alpaca reports it closed, for up to `timeout_s`; returns
    the order as last seen. An order that filled first comes back filled."""
    def cancel_and_wait(order_id: str, timeout_s: float = 10.0, poll_s: float = 0.25) -> BrokerOrder {
        self.cancel(order_id);
        deadline = time.monotonic() + timeout_s;
        while True {
            seen = self.order(order_id);
            if not seen.working() or time.monotonic() >= deadline {
                return seen;
            }
            time.sleep(poll_s);
        }
    }

    """A response that must be a JSON object."""
    def _object(method: str, path: str, params: dict[str, str] | None = None, payload: dict[str, str | dict[str, str]] | None = None, retry: bool = True) -> dict[str, object] {
        text = self._request(method, path, params, payload, retry);
        try {
            parsed: object = json.loads(text);
        } except ValueError {
            raise BrokerError(path=path, status=200, detail=f"not JSON: {text[:200]}");
        }
        if not isinstance(parsed, dict) {
            raise BrokerError(path=path, status=200, detail=f"expected a JSON object: {text[:200]}");
        }
        return parsed;
    }

    """A response that must be a JSON list of objects."""
    def _list(method: str, path: str, params: dict[str, str] | None = None) -> list[dict[str, object]] {
        text = self._request(method, path, params);
        try {
            parsed: object = json.loads(text);
        } except ValueError {
            raise BrokerError(path=path, status=200, detail=f"not JSON: {text[:200]}");
        }
        if not isinstance(parsed, list) {
            raise BrokerError(path=path, status=200, detail=f"expected a JSON list: {text[:200]}");
        }
        return _rows(parsed);
    }

    """The response body. A GET or DELETE is retried on a timeout, connection error, 429, or 5xx
    with backoff; a POST never is, since `submit` decides that from the client order ID."""
    def _request(method: str, path: str, params: dict[str, str] | None = None, payload: dict[str, str | dict[str, str]] | None = None, retry: bool = True) -> str {
        (bucket, http) = (self.bucket, self._http);
        if bucket is None or http is None {
            raise BrokerError(path=path, detail="the client is not initialized");
        }
        attempts = self.max_retries + 1 if retry else 1;
        failure = BrokerError(path=path);
        for attempt in range(attempts) {
            bucket.acquire();
            try {
                response = http.request(method, self.base_url + path, params=params, json=payload, headers=self.headers);
            } except httpx.TransportError as e {
                failure = BrokerError(path=path, detail=type(e).__name__);
            } else {
                if 200 <= response.status_code < 300 {
                    return response.text;
                }
                failure = BrokerError(path=path, status=response.status_code, detail=_message(response.text));
                if response.status_code != 429 and response.status_code < 500 {
                    raise failure;
                }
            }
            if attempt + 1 < attempts {
                time.sleep(self.backoff_s * (2 ** attempt));
            }
        }
        raise failure;
    }
}

"""Alpaca's error message from a response body, or the start of the body."""
def _message(text: str) -> str {
    try {
        parsed = json.loads(text);
    } except ValueError {
        return text[:200];
    }
    if isinstance(parsed, dict) and parsed.get("message") {
        return str(parsed["message"])[:300];
    }
    return text[:200];
}

"""The objects in a parsed JSON value, or none when it is not a list."""
def _rows(value: object) -> list[dict[str, object]] {
    return [r for r in value if isinstance(r, dict)] if isinstance(value, list) else [];
}

def _text(row: dict[str, object], key: str) -> str {
    value = row.get(key);
    return "" if value is None else str(value);
}

def _number(row: dict[str, object], key: str) -> float {
    value = row.get(key);
    return float(str(value)) if value is not None and str(value) != "" else 0.0;
}

def _shares(value: object) -> int {
    return int(float(str(value))) if value is not None and str(value) != "" else 0;
}

def _price(value: object) -> float | None {
    return float(str(value)) if value is not None and str(value) != "" else None;
}

def _order(row: dict[str, object]) -> BrokerOrder {
    return BrokerOrder(
        id=_text(row, "id"),
        client_order_id=_text(row, "client_order_id"),
        symbol=_text(row, "symbol"),
        side=_text(row, "side"),
        order_type=_text(row, "type") or _text(row, "order_type"),
        time_in_force=_text(row, "time_in_force"),
        qty=_shares(row.get("qty")),
        filled_qty=_shares(row.get("filled_qty")),
        status=_text(row, "status"),
        filled_avg_price=_price(row.get("filled_avg_price")),
        limit_price=_price(row.get("limit_price")),
        stop_price=_price(row.get("stop_price")),
        order_class=_text(row, "order_class"),
        submitted_at=_text(row, "submitted_at"),
        filled_at=_text(row, "filled_at"),
        canceled_at=_text(row, "canceled_at"),
        legs=[_order(leg) for leg in _rows(row.get("legs"))]
    );
}

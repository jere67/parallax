"""A read cache for the dashboard's views.

The persistent graph loads one node per database query, so a view that walks every run or
order costs about a thousand queries, seconds on a local Postgres and more as the record
grows. The pipeline writes at most once a minute (run/trading.jac), so the endpoints keep
each view for FRESH_SECONDS and a scheduled job rebuilds the main ones every minute
(dashboard/api.jac), which keeps page loads instant. One lock lets a single caller build at a
time; anyone who waited on it takes the view that caller built.
"""
import threading;
import time;

glob FRESH_SECONDS: float = 120.0;
glob MAX_ENTRIES: int = 512;
glob _BUILD_LOCK: threading.Lock = threading.Lock();

obj Entry {
    has built: float,
        value: object;
}

obj ViewCache {
    has entries: dict[str, Entry] = {};

    """The view under `key` if it is fresh, or a new one from `build(*args)`."""
    def get[T](key: str, build: Callable[..., T], *args: object) -> T {
        found = self.fresh(key);
        if found is not None {
            return found.value;
        }
        with _BUILD_LOCK {
            found = self.fresh(key);
            if found is not None {
                return found.value;
            }
            value = build(*args);
            self.put(key, value);
            return value;
        }
    }

    def fresh(key: str) -> Entry | None {
        found = self.entries.get(key);
        return found if found is not None and time.monotonic() - found.built < FRESH_SECONDS else None;
    }

    """Keep `value` under `key`, dropping the oldest views beyond MAX_ENTRIES."""
    def put(key: str, value: object) {
        entries = dict(self.entries);
        entries[key] = Entry(built=time.monotonic(), value=value);
        while len(entries) > MAX_ENTRIES {
            oldest = min(entries, key=lambda (k: str) { entries[k].built; });
            del entries[oldest];
        }
        self.entries = entries;
    }

    def clear {
        self.entries = {};
    }
}

glob VIEWS: ViewCache = ViewCache();

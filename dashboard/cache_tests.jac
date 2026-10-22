"""The dashboard's read cache (dashboard/cache.jac)."""
import from dashboard.cache { Entry, FRESH_SECONDS, MAX_ENTRIES, ViewCache }

obj Counter {
    has calls: int = 0;

    def build(label: str) -> str {
        self.calls += 1;
        return f"{label}-{self.calls}";
    }
}

test "a fresh view is built once, and a stale one is built again" {
    cache = ViewCache();
    counter = Counter();
    assert cache.get("a", counter.build, "view") == "view-1";
    assert cache.get("a", counter.build, "view") == "view-1" and counter.calls == 1;
    old = cache.entries["a"];
    cache.entries = {"a": Entry(built=old.built - FRESH_SECONDS - 1.0, value=old.value)};
    assert cache.get("a", counter.build, "view") == "view-2" and counter.calls == 2;
}

test "a put replaces a view, and the oldest views go beyond the limit" {
    cache = ViewCache();
    counter = Counter();
    cache.put("a", "kept");
    assert cache.get("a", counter.build, "view") == "kept" and counter.calls == 0;
    for i in range(MAX_ENTRIES + 1) {
        cache.put(f"k{i}", i);
    }
    assert len(cache.entries) == MAX_ENTRIES and "a" not in cache.entries and "k0" not in cache.entries;
    assert f"k{MAX_ENTRIES}" in cache.entries;
}

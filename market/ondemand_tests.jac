"""The guards around on-demand reads, and matching a company to its Wikipedia article."""
import from market.ondemand { Allowance, Busy, TimedCache, matching_title, name_words }

test "the allowance refuses past its burst rather than making anyone wait" {
    allowance = Allowance(per_minute=0.001, burst=2.0);
    allowance.take();
    allowance.take();
    refused = False;
    try {
        allowance.take();
    } except Busy {
        refused = True;
    }
    assert refused;
}

test "a cached answer lasts as long as asked" {
    cache = TimedCache();
    cache.put("k", 1);
    assert cache.get("k", 60.0) == 1;
    assert cache.get("k", 0.0) is None;
    assert cache.get("other", 60.0) is None;
}

test "an article must share a distinctive word with the company" {
    assert name_words("The Boeing Company") == {"boeing"};
    assert matching_title(["List of S&P 500 companies", "Apple Inc."], "Apple Inc.") == "Apple Inc.";
    assert matching_title(["List of S&P 500 companies"], "Apple Inc.") == "";
    assert matching_title(["Corporation", "Holdings Group"], "Acme Holdings Group Corporation") == "";
}

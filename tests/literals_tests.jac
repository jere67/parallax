"""Source rules the compiler does not enforce yet."""
import re;
import from pathlib { Path }

glob PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent;
glob SKIP_DIRS: set[str] = {".git", ".jac", "dist", "node_modules"};
# A digit group, then a fraction or an exponent, outside a string: `50_000_000.0`, `1_000e3`.
glob UNDERSCORE_FLOAT: re.Pattern[str] = re.compile(r"(?<![\w.\"'])\d+(?:_\d+)+(?:\.\d*|[eE][-+]?\d+)");

"""Jac 0.39.2 reads a float literal with digit separators only up to the first underscore, so
`50_000_000.0` is 50.0 (an integer such as `10_000_000` is read whole). Write such a float as
`50e6`. Remove this test once the compiler reads them whole."""
test "no float literal uses digit separators" {
    found: list[str] = [];
    for path in PROJECT_ROOT.rglob("*.jac") {
        if SKIP_DIRS & set(path.relative_to(PROJECT_ROOT).parts) {
            continue;
        }
        for (n, line) in enumerate(path.read_text().splitlines(), start=1) {
            code = re.sub(r"\"[^\"]*\"|'[^']*'|`[^`]*`|#.*$", "", line);
            if UNDERSCORE_FLOAT.search(code) {
                found.append(f"{path.relative_to(PROJECT_ROOT)}:{n}: {line.strip()}");
            }
        }
    }
    assert found == [], found;
}

test "the separator rule sees what it guards against" {
    assert UNDERSCORE_FLOAT.search("x: float = 50_000_000.0;") is not None;
    assert UNDERSCORE_FLOAT.search("budget = 10_000_000;") is None;
    assert UNDERSCORE_FLOAT.search("y = 50e6;") is None;
}

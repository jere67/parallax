"""Server settings in jac.toml that the app's design depends on."""
import tomllib;
import from pathlib { Path }

glob CONFIG: dict[str, any] = tomllib.loads((Path(__file__).resolve().parent.parent / "jac.toml").read_text());

"""The model rate limiter, the run guards, and the caches are module globals, so a second worker
process would keep its own copies: twice the provider requests the limiter allows, and a run guard
the other worker cannot see. Since Jac 0.38 an unset count forks one worker per core."""
test "the server runs one worker process" {
    assert str(CONFIG["serve"]["workers"]["count"]) == "1";
}

"""An unset ADMIN_PASSWORD makes the server mint a one-time admin password. A fixed fallback such as
`changeme` is on Jac's common-password list, so a new server would refuse to start with it."""
test "the admin password has no fixed fallback" {
    assert CONFIG["scale"]["admin"]["default_password"] == "${ADMIN_PASSWORD:-}";
}

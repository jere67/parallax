"""Server settings in jac.toml that the app's design depends on."""
import tomllib;
import from pathlib { Path }

glob CONFIG: dict[str, any] = tomllib.loads((Path(__file__).resolve().parent.parent / "jac.toml").read_text());

"""The model rate limiter, the run guards, and the view caches are module globals, so a second pod
would keep its own copies: twice the provider requests the limiter allows, and a run guard the
other pod cannot see."""
test "a deploy runs one pod" {
    kube = CONFIG["scale"]["kubernetes"];
    assert kube["min_replicas"] == 1 and kube["max_replicas"] == 1;
}

"""The graph is the team's record, so a deploy keeps it in a Postgres of its own on a persistent
volume rather than wiring no database."""
test "a deploy provisions its own Postgres" {
    assert CONFIG["scale"]["kubernetes"]["database_mode"] == "provision";
}

"""Starts a JacHammer host on the prebuilt release, `release/parallax.jab`.

JacHammer starts an app by compiling its entry-point, and gives up when nothing answers on :8000
within about five minutes. Its machines compile about five times slower than a laptop, so the
whole app (about 90 s here) no longer fits. jac.toml's `[hosted]` table points the host's start
script at this module instead: it compiles in a moment, and on import it hands the process to the
release, which `jac run` serves with no compiling at all (see scripts/build-release.sh).

Everything else (`jac run`, `jac build`, tests, CI) reads `[project]` and never comes here.
"""
import os;
import shutil;
import sys;

glob RELEASE_ENV: str = "PARALLAX_RELEASE",
     PORT_ENV: str = "PARALLAX_PORT";

"""The release to serve: PARALLAX_RELEASE when set, else release/parallax.jab beside this file."""
def release_path -> str {
    return os.environ.get(RELEASE_ENV) or os.path.join(os.path.dirname(os.path.abspath(__file__)), "release", "parallax.jab");
}

"""The `jac` launcher running this process: /proc/self/exe on Linux, else `jac` on the PATH."""
def launcher -> str {
    if os.path.exists("/proc/self/exe") {
        return os.path.realpath("/proc/self/exe");
    }
    return shutil.which("jac") or "jac";
}

"""The command that serves the release on the host's port."""
def release_command -> list[str] {
    return ["jac", "run", release_path(), "--port", os.environ.get(PORT_ENV) or "8000"];
}

"""Replaces this process with the release's server. The host tracks this process, so it keeps
tracking the server; nothing after the call runs."""
def hand_off -> int {
    release = release_path();
    if not os.path.isfile(release) {
        sys.stderr.write(f"launch: no release at {release}; run scripts/build-release.sh and commit it\n");
        sys.exit(1);
    }
    sys.stdout.write(f"launch: serving {release}\n");
    sys.stdout.flush();
    os.execv(launcher(), release_command());
    return 0;
}

# Runs on import, the first thing the host's `jac run --serve launch.jac` does with this module.
glob HANDED_OFF: int = hand_off();

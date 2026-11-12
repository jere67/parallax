"""The servers the sign-in screen offers with one tap."""

import from .servers { dev_host, given_servers }
import from .api { is_local_host }

obj Preset {
    has label: str,
        url: str,
        note: str;
}

glob LIVE_NOTE: str = "The team's forward test",
     DEMO_NOTE: str = "Invented history, labeled as demo";

"""The team's live server and a demo server. Addresses given at start (a tunnel's) come first;
otherwise both are on the computer running the dev server, at ports 8100 and 8200, when the
phone reaches that computer by its address. A tunnel's name has no such ports, so then there
is nothing to offer and the address is typed."""
def:pub presets -> list[Preset] {
    given = given_servers();
    offered: list[Preset] = [];
    if given.get("live", "") {
        offered.append(Preset(label="Live", url=given["live"], note=LIVE_NOTE));
    }
    if given.get("demo", "") {
        offered.append(Preset(label="Demo", url=given["demo"], note=DEMO_NOTE));
    }
    if len(offered) > 0 {
        return offered;
    }
    host = dev_host();
    if not host or not is_local_host(host) {
        return [];
    }
    return [
        Preset(label="Live", url=f"http://{host}:8100", note=LIVE_NOTE),
        Preset(label="Demo", url=f"http://{host}:8200", note=DEMO_NOTE)
    ];
}

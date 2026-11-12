"""Parallax on a phone: a native client for a Parallax server, written in Jac with mobUI.

The server runs the committee and keeps every record; this app signs in to it and reads three
things: the portfolio, the latest morning run, and each decision's trail. While it is open, and
each time it returns to the foreground, it checks for a new run and raises a notification when
one has come in. It only reads, so it can never place an order or start a run."""

import from "react" { useEffect }
import from "@jac/mobui" { View, Text, Pressable, ActivityIndicator, StatusBar }
import from .theme { C, S, R, F, styles }
import from .fonts { SERIF, use_display_font }
import from .api { call, server_label }
import from .session { clear_session, load_session, save_session }
import from .alerts { alert, allow_alerts, on_foreground }
import from .views { RunView }
import from .format { day_label, first_sentence }
import from .components.Icon { Icon }
import from .components.parts { Notice }
import from .screens.SignIn { SignIn }
import from .screens.Portfolio { Portfolio }
import from .screens.Today { Today }
import from .screens.Trail { Trail }

glob CHECK_EVERY_MS: int = 60000;

"""Names one saved run, so the app can tell when a different one comes in."""
def run_key(run: RunView) -> str {
    return f"{run.run_date}|{run.status}|{run.finished_at}";
}

def Tab(name: str, label: str, icon: str, chosen: bool, onPress: Callable[[], None]) -> JsxElement {
    <Pressable key={name} onPress={onPress} style={{"flex": 1, "alignItems": "center", "gap": 3, "paddingTop": S.sm, "paddingBottom": S.xs}}>
        <Icon name={icon} size={22} color={C.accent if chosen else C.faint}/>
        <Text style={{"color": C.accent if chosen else C.faint, "fontSize": 11, "fontWeight": "600"}}>{label}</Text>
    </Pressable>
}

def:pub app -> JsxElement {
    has session: dict[str, str] | None = None,
        booting: bool = True,
        tab: str = "portfolio",
        trail: dict[str, str] | None = None,
        news: str = "",
        alerts_on: bool = False,
        version: int = 0;

    fonts_ready = use_display_font();

    async can with entry {
        session = await load_session();
        booting = False;
    }

    async def signed_in(next: dict[str, str]) {
        session = next;
        tab = "portfolio";
        trail = None;
        await save_session(next);
        alerts_on = await allow_alerts();
    }

    async def sign_out {
        session = None;
        trail = None;
        news = "";
        await clear_session();
    }

    """Look for a run the reader has not seen; when there is one, say so on screen and in a
    notification, then remember it."""
    async def check_run {
        current = session;
        if not current {
            return;
        }
        got = await call(current["server"], current["token"], "get_run", {"run_date": ""});
        if got.signed_out {
            await sign_out();
            return;
        }
        if not got.ok or not got.data {
            return;
        }
        run = got.data as RunView;
        key = run_key(run);
        seen = current["seen"] or "";
        if key == seen {
            return;
        }
        if seen {
            title = f"Morning run {'failed' if run.status == 'failed' else 'finished'}";
            body = f"The {day_label(run.run_date)} run {'failed' if run.status == 'failed' else 'is in'}. {first_sentence(run.summary)}".strip();
            news = body;
            version = version + 1;
            await alert(title, body);
        }
        session = {**current, "seen": key};
        await save_session(session);
    }

    # While signed in: check now, every minute, and on each return to the foreground.
    # `check_run` does nothing while signed out.
    useEffect(lambda {
        check = lambda { check_run(); };
        check_run();
        timer = setInterval(check, CHECK_EVERY_MS);
        stop = on_foreground(check);
        return lambda {
            clearInterval(timer);
            stop();
        };
    }, [session and session["token"]]);

    if booting or not fonts_ready {
        return <View style={[styles.screen, {"justifyContent": "center"}]}><ActivityIndicator color={C.accent}/></View>;
    }

    if not session {
        return <View style={styles.screen}><StatusBar barStyle="light-content"/><SignIn server="" onSignedIn={signed_in}/></View>;
    }

    server = session["server"];
    token = session["token"];
    open_trail = lambda (day: str, ticker: str) { trail = {"day": day, "ticker": ticker}; };

    if trail {
        return <View style={styles.screen}>
            <StatusBar barStyle="light-content"/>
            <Trail server={server} token={token} day={trail["day"]} ticker={trail["ticker"]} onBack={lambda { trail = None; }} onSignedOut={sign_out} onOpen={open_trail}/>
        </View>;
    }

    <View style={styles.screen}>
        <StatusBar barStyle="light-content"/>
        <View style={{"flexDirection": "row", "alignItems": "center", "justifyContent": "space-between", "paddingHorizontal": S.lg, "paddingVertical": S.sm, "borderBottomWidth": 1, "borderBottomColor": C.line}}>
            <View style={{"gap": 0}}>
                <Text style={{"color": C.text, "fontFamily": SERIF, "fontSize": 26, "lineHeight": 30}}>Parallax</Text>
                <Text style={styles.faint}>{f"{session['username']} on {server_label(server)}"}</Text>
            </View>
            <View style={{"flexDirection": "row", "alignItems": "center", "gap": S.lg}}>
                <Pressable hitSlop={10} onPress={lambda { check_run(); }} accessibilityLabel="Check for a new run">
                    <Icon name="bell" size={20} color={C.accent if alerts_on else C.faint}/>
                </Pressable>
                <Pressable hitSlop={10} onPress={sign_out} accessibilityLabel="Sign out">
                    <Icon name="out" size={20} color={C.faint}/>
                </Pressable>
            </View>
        </View>
        {(
            <View style={{"width": "100%", "maxWidth": 560, "alignSelf": "center", "paddingHorizontal": S.lg, "paddingTop": S.md}}>
                <Notice text={news} tone="accent" onPress={lambda { news = ""; tab = "today"; }}/>
            </View>
        ) if news else None}
        <View style={{"flex": 1}}>
            {(<Portfolio server={server} token={token} onSignedOut={sign_out} onOpenTrail={open_trail}/>) if tab == "portfolio" else <Today server={server} token={token} version={version} onSignedOut={sign_out} onOpenTrail={open_trail}/>}
        </View>
        <View style={{"flexDirection": "row", "borderTopWidth": 1, "borderTopColor": C.line, "backgroundColor": C.bg}}>
            <Tab name="portfolio" label="Portfolio" icon="chart" chosen={tab == "portfolio"} onPress={lambda { tab = "portfolio"; }}/>
            <Tab name="today" label="Today" icon="sunrise" chosen={tab == "today"} onPress={lambda { tab = "today"; }}/>
        </View>
    </View>
}

"""Sign in: choose a server, then sign in with a Parallax account on it."""

import from "@jac/mobui" { View, Text, TextInput, Pressable, ScrollView, ActivityIndicator, KeyboardAvoidingView, Platform }
import from ..theme { C, S, R, F, styles }
import from ..fonts { SERIF }
import from ..api { clean_server, server_label, sign_in }
import from ..presets { Preset, presets }
import from ..components.Icon { Icon }
import from ..components.parts { Notice }

def Field(label: str, value: str, onChange: Callable[[str], None], placeholder: str = "", secret: bool = False, url: bool = False, onSubmit: Callable[[], None] | None = None) -> JsxElement {
    <View style={{"gap": 6}}>
        <Text style={styles.note}>{label}</Text>
        <TextInput
            value={value}
            onChangeText={onChange}
            placeholder={placeholder}
            placeholderTextColor={C.faint}
            secureTextEntry={secret}
            autoCapitalize="none"
            autoCorrect={False}
            keyboardType={"url" if url else "default"}
            returnKeyType={"go" if secret else "next"}
            onSubmitEditing={onSubmit}
            style={{"color": C.text, "fontSize": F.md, "backgroundColor": C.raised, "borderWidth": 1, "borderColor": C.line, "borderRadius": R.md, "paddingVertical": S.md, "paddingHorizontal": S.lg}}
        />
    </View>
}

def PresetChip(p: Preset, chosen: bool, onPress: Callable[[], None]) -> JsxElement {
    <Pressable onPress={onPress} style={{"flex": 1, "gap": 2, "padding": S.md, "borderRadius": R.md, "borderWidth": 1, "borderColor": C.accent if chosen else C.line, "backgroundColor": C.accentSoft if chosen else C.raised}}>
        <Text style={{"color": C.accent if chosen else C.text, "fontSize": F.md, "fontWeight": "600"}}>{p.label}</Text>
        <Text style={styles.faint}>{p.note}</Text>
    </Pressable>
}

def:pub SignIn(server: str, onSignedIn: Callable[[dict], None]) -> JsxElement {
    has address: str = "",
        username: str = "",
        password: str = "",
        busy: bool = False,
        problem: str = "";

    offered = presets();

    async can with entry {
        address = server_label(server) if server else (server_label(offered[0].url) if len(offered) > 0 else "");
    }

    async def submit {
        base = clean_server(address);
        if not base or not username.strip() or not password {
            problem = "Enter the server, your username, and your password.";
            return;
        }
        busy = True;
        problem = "";
        reply = await sign_in(base, username, password);
        busy = False;
        if not reply.ok {
            problem = reply.problem;
            return;
        }
        password = "";
        onSignedIn({"server": base, "token": reply.data, "username": username.strip()});
    }

    <KeyboardAvoidingView style={styles.screen} behavior={"padding" if Platform.OS == "ios" else None}>
        <ScrollView style={styles.scroll} contentContainerStyle={[styles.content, {"paddingTop": S.xxl * 2}]} keyboardShouldPersistTaps="handled">
            <View style={{"gap": S.sm}}>
                <Text style={{"color": C.text, "fontFamily": SERIF, "fontSize": 56, "lineHeight": 60}}>Parallax</Text>
                <Text style={[styles.body, {"color": C.muted}]}>An AI investment committee that researches S&P 500 stocks and trades on paper. Sign in to follow it from your phone.</Text>
            </View>
            {(
                <View style={{"gap": S.sm}}>
                    <Text style={styles.note}>Server</Text>
                    <View style={{"flexDirection": "row", "gap": S.sm}}>
                        {[<PresetChip key={p.label} p={p} chosen={clean_server(address) == p.url} onPress={lambda { address = server_label(p.url); }}/> for p in offered]}
                    </View>
                </View>
            ) if len(offered) > 0 else None}
            <View style={{"gap": S.lg}}>
                <Field label={"Or any server address" if len(offered) > 0 else "Server address"} value={address} onChange={lambda (t: str) { address = t; }} placeholder="parallax.jaseci.app" url={True}/>
                <Field label="Username" value={username} onChange={lambda (t: str) { username = t; }} placeholder="admin"/>
                <Field label="Password" value={password} onChange={lambda (t: str) { password = t; }} secret={True} onSubmit={submit}/>
            </View>
            {(<Notice text={problem} tone="down"/>) if problem else None}
            <Pressable onPress={submit} disabled={busy} style={lambda (state: any) { return {"flexDirection": "row", "justifyContent": "center", "alignItems": "center", "gap": S.sm, "paddingVertical": S.md + 2, "borderRadius": R.md, "backgroundColor": C.accent, "opacity": 0.7 if (busy or state.pressed) else 1.0}; }}>
                {(<ActivityIndicator color={C.onAccent}/>) if busy else None}
                <Text style={{"color": C.onAccent, "fontSize": F.md, "fontWeight": "700"}}>{"Signing in" if busy else "Sign in"}</Text>
            </Pressable>
            <View style={[styles.row, {"alignItems": "flex-start"}]}>
                <Icon name="server" size={16} color={C.faint}/>
                <Text style={[styles.faint, {"flex": 1}]}>Use the account you have on that server. The app only reads: it cannot place an order or start a run. An educational project; not investment advice.</Text>
            </View>
        </ScrollView>
    </KeyboardAvoidingView>
}

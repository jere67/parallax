import from "@jac/runtime" { Link, jacIsLoggedIn }
import from dashboard.ui.parts { Empty }

def:pub NotFound -> JsxElement {
    <Empty title="Page not found">
        There is nothing at this address.
        {" "}
        <Link to={"/app" if jacIsLoggedIn() else "/"} className="text-accent hover:underline">{"Go to your portfolio" if jacIsLoggedIn() else "Go to the front page"}</Link>.
    </Empty>
}

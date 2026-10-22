import from "@jac/runtime" { Link }
import from dashboard.ui.parts { Empty }

def:pub NotFound -> JsxElement {
    <Empty title="Page not found">
        There is nothing at this address.
        {" "}
        <Link to="/" className="text-accent hover:underline">Go to the portfolio</Link>.
    </Empty>
}

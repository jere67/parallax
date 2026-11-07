"""The product's mark, name, and theme switch, shared by the public pages and the app's top bar."""
import from "@jac/runtime" { Link }
import from "lucide-react" { Moon, Sun }
import from dashboard.ui.theme { is_dark, set_theme }

glob:pub PRODUCT: str = "Parallax";
# The same words as action/insights.jac DISCLAIMER, which stays server-side with the cards.
glob:pub DISCLAIMER: str = "An educational student project trading simulated money. Nothing here is investment advice, and past simulated performance does not predict future results.";
glob:pub REPO_URL: str = "https://github.com/jere67/eecs449-project";
glob:pub DOCS_URL: str = "https://jere67.github.io/parallax/";

"""The mark: five specialists' votes on an arc, meeting in one decision."""
def:pub Mark -> JsxElement {
    <svg viewBox="0 0 20 20" className="size-5 text-accent" aria-hidden="true">
        <circle cx="3" cy="13" r="1.6" fill="currentColor" opacity="0.55"/>
        <circle cx="5.6" cy="6.4" r="1.6" fill="currentColor" opacity="0.7"/>
        <circle cx="10" cy="3.4" r="1.6" fill="currentColor" opacity="0.85"/>
        <circle cx="14.4" cy="6.4" r="1.6" fill="currentColor" opacity="0.7"/>
        <circle cx="17" cy="13" r="1.6" fill="currentColor" opacity="0.55"/>
        <circle cx="10" cy="13" r="3" fill="currentColor"/>
    </svg>
}

"""The mark and name, linking to `to`."""
def:pub Wordmark(to: str = "/") -> JsxElement {
    <Link to={to} className="flex items-center gap-2" aria-label={PRODUCT + ", home"}>
        <Mark/>
        <span className="display text-[19px] leading-none">{PRODUCT}</span>
    </Link>
}

def:pub ThemeSwitch -> JsxElement {
    has dark: bool = is_dark();

    def flip {
        set_theme("light" if dark else "dark");
        dark = not dark;
    }

    <button
        type="button"
        onClick={flip}
        className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover hover:text-text md:size-8"
        aria-label={"Switch to light theme" if dark else "Switch to dark theme"}
        title={"Light theme" if dark else "Dark theme"}
    >
        {<Sun size={16} strokeWidth={1.75}/> if dark else <Moon size={16} strokeWidth={1.75}/>}
    </button>
}

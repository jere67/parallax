"""The display face on the web build: Instrument Serif when the browser has it, else a serif.
`fonts.native.jac` loads the real face on a phone; both export the same names."""

glob:pub SERIF: str = "'Instrument Serif', Georgia, serif";

"""True once the display face can be used. A browser falls back on its own, so it is always ready."""
def:pub use_display_font -> bool {
    return True;
}

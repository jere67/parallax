"""The display face on a phone: Instrument Serif, the web dashboard's headline face, loaded
through expo-font. Same names as `fonts.jac`."""

import from "@expo-google-fonts/instrument-serif" { useFonts, InstrumentSerif_400Regular }

glob:pub SERIF: str = "InstrumentSerif_400Regular";

"""True once Instrument Serif has loaded, or failed to; the app waits for it so headlines do
not jump from the system face to the serif."""
def:pub use_display_font -> bool {
    (loaded, failed) = useFonts({"InstrumentSerif_400Regular": InstrumentSerif_400Regular});
    return bool(loaded or failed);
}

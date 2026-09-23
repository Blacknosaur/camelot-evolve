package app.camelot.camera

import androidx.compose.ui.graphics.Color

/** Mirrors `EventKind` on iOS: the raw names travel on the wire, so they must not drift. */
enum class EventKind(val label: String, val tint: Color) {
    GOAL("Goal", Color(0xFFB6F36A)),
    SHOT("Shot", Color(0xFF6AB7FF)),
    SAVE("Save", Color(0xFFB89AFF)),
    FOUL("Foul", Color(0xFFFFAA55)),
    CARD("Card", Color(0xFFFF6B6B)),
    NOTE("Note", Color(0xFFF5D76E)),
}

import AppKit
import SwiftUI

extension Color {
    /// sRGB components for persisting a SwiftUI colour into the shared analysis models.
    var rgbComponents: (Double, Double, Double) {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }
}
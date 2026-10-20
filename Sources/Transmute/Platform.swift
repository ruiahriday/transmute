// The few AppKit types the converters share with the iPhone and iPad app, under one name.
#if canImport(AppKit)
import AppKit

typealias PlatformFont = NSFont

extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}
#else
import UIKit

typealias PlatformFont = UIFont

extension UIFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.traitBold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.traitItalic) }
}
#endif

import SwiftUI

extension View {
    /// Mac editor windows get a minimum size; on iPhone and iPad the editor fills the screen.
    @ViewBuilder
    func editorWindowSize(minWidth: CGFloat, idealWidth: CGFloat, minHeight: CGFloat, idealHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// Lets a tall editor scroll on iPhone and iPad; Mac windows are big enough as they are.
    @ViewBuilder
    func scrollsOnPhone() -> some View {
        #if os(macOS)
        self
        #else
        ScrollView { self }
        #endif
    }
}

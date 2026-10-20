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

/// A row of editor controls. On the Mac it's a plain row; on iPhone and iPad the
/// controls wrap onto more lines instead of squeezing their labels letter by letter.
struct ControlRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HStack(spacing: spacing) { content }
        #else
        WrappingHStack(spacing: spacing) { content }
        #endif
    }
}

/// A titled settings row in the editors: title on the left on the Mac, above the controls on iPhone and iPad.
struct EditorRow<Content: View>: View {
    let title: String
    var titleWidth: CGFloat = 60
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HStack(spacing: 10) {
            Text(title)
                .frame(width: titleWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        #else
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            WrappingHStack(spacing: 10) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

#if os(iOS)
/// Lays out its children left to right at their natural sizes, starting a new line when one runs out of room.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = arrange(subviews, width: proposal.width ?? .infinity).size
        // Take the whole offered width, so placing the controls wraps them exactly as measured here.
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: size.height) }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let maxWidth = width.isFinite ? max(width, 1) : .greatestFiniteMagnitude
        var frames: [CGRect] = []
        var lines: [(range: Range<Int>, height: CGFloat)] = []
        var lineStart = 0, x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if x > 0 && x + size.width > maxWidth {
                lines.append((lineStart..<index, lineHeight))
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0; lineStart = index
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        lines.append((lineStart..<frames.count, lineHeight))
        // Centre each control vertically within its line.
        for line in lines {
            for index in line.range {
                frames[index].origin.y += (line.height - frames[index].height) / 2
            }
        }
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}
#endif

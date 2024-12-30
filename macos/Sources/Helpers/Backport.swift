import SwiftUI

// All backport view/scene modifiers go as an extension on this. We use this
// so we can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Backport where Content: Scene {
    // None currently
}

extension Backport where Content: View {
    func pointerVisibility(_ v: BackportVisibility) -> some View {
        return content
    }

    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        return content
    }
}

enum BackportVisibility {
    case automatic
    case visible
    case hidden

    @available(macOS 15, *)
    var official: Visibility {
        switch self {
        case .automatic: return .automatic
        case .visible: return .visible
        case .hidden: return .hidden
        }
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight
}

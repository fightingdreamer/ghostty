import GhosttyKit

extension FullscreenMode {
    /// Initialize from a Ghostty fullscreen action.
    static func from(ghostty: ghostty_action_fullscreen_e) -> Self? {
        switch ghostty {
        case GHOSTTY_FULLSCREEN_NATIVE:
            return .native

        case GHOSTTY_FULLSCREEN_NON_NATIVE:
            return .nonNative

        case GHOSTTY_FULLSCREEN_NON_NATIVE_VISIBLE_MENU:
            return .nonNativeVisibleMenu

        default:
            return nil
        }
    }
}

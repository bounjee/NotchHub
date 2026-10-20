import AppKit

enum NotchGeometry {
    /// The built-in display, only if it has a notch.
    @MainActor
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 && screen.safeAreaInsets.top > 0
        }
    }

    @MainActor
    static func notchSize(of screen: NSScreen) -> CGSize {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let width = left > 0 && right > 0 ? screen.frame.width - left - right : 185
        return CGSize(width: width, height: screen.safeAreaInsets.top)
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// Saves the window's position and size whenever it moves or resizes, and
/// puts it back there when the app opens again.
///
/// SwiftUI only restores a window's frame through macOS state restoration,
/// which "Close windows when quitting an application" (on by default) turns
/// off, so this uses AppKit's frame autosave instead.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { AutosaveView(name: name) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AutosaveView: NSView {
        let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            // Read before autosaving starts: SwiftUI sizes and centers a new
            // window after this, and that would be saved over the old frame.
            let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
            if let saved { window.setFrame(from: saved) }
            DispatchQueue.main.async {
                if let saved { window.setFrame(from: saved) }
                // False when another window already uses the name; that one keeps saving.
                window.setFrameAutosaveName(self.name)
            }
        }
    }
}
#endif

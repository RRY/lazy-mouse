import SwiftUI
import AppKit
import HIDPPKit

@main
struct LazyMouseApp: App {
    @StateObject private var model = MouseModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // The battery level sits right in the icon so the most frequent glance at the
            // menu bar needs no click. A problem should be just as visible without one,
            // hence the different symbol.
            HStack(spacing: 3) {
                Image(systemName: model.connected ? "computermouse" : "exclamationmark.triangle")
                if let percent = model.batteryPercent {
                    Text("\(percent)%")
                }
            }
            // MenuBarExtra does not redraw its label when only the content changes. The
            // changing identity forces the rebuild.
            .id("\(model.connected)-\(model.batteryPercent ?? -1)")
        }
        // No Settings scene: SettingsWindowController manages the window, because it cannot
        // be opened reliably from a MenuBarExtra in menu style.
    }
}

struct MenuContent: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        // The menu deliberately holds actions only: plain text is drawn as a disabled entry
        // and is hard to read. Battery and DPI live in the icon and the settings window.
        if model.connected {
            Menu(LocalizedStringKey("menu.dpi")) {
                ForEach(model.cycleSteps, id: \.self) { step in
                    Button {
                        model.setDPI(step)
                    } label: {
                        Text(step == model.currentDPI ? "✓ \(step)" : "\(step)")
                    }
                }
            }

            // The scroll wheel lives in the settings window only: needed less often than the
            // DPI switching, and the menu should stay short.
            Toggle(LocalizedStringKey("menu.dpiButtonActive"), isOn: $model.cycleEnabled)
        } else if model.permissionDenied {
            // Without this permission IOHIDManagerOpen returns kIOReturnNotPermitted. Another
            // connection attempt is bound to fail, so the entry leads straight to the only
            // place where it can be fixed. What exactly is wrong is stated in the settings
            // window.
            Button(LocalizedStringKey("action.openInputMonitoring")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            Button(LocalizedStringKey("action.reconnect")) { model.connect() }
        }

        Divider()
        Toggle(LocalizedStringKey("label.launchAtLogin"), isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()
        Button(LocalizedStringKey("menu.settings")) {
            SettingsWindowController.shared.show(model: model)
        }
        .keyboardShortcut(",", modifiers: .command)
        Button(LocalizedStringKey("menu.quit")) {
            model.releaseButtonOnQuit()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

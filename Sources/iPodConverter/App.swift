import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }
        AppearanceSettings.shared.apply()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.shared.setup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct IPodConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        WindowGroup("iPod Converter") {
            ContentView(store: store)
                .frame(minWidth: 640, minHeight: 540)
                .onAppear {
                    // Файлы, переданные аргументами: open -a "iPod Converter" --args video.mp4
                    let files = CommandLine.arguments.dropFirst()
                        .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    store.add(files)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L.openVideo) { store.openPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

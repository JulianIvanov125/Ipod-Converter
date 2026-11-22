import AppKit
import SwiftUI

// MARK: - Как синхронизировать через Finder

/// Кнопка «?» рядом с «В Музыку/TV»: открывает подсказку; при подключённом iPod — сразу «Открыть Finder».
struct SyncGuideButton: View {
    @Bindable var store: Store
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: IPodDetector.shared.connected.isEmpty ? "questionmark.circle" : "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(IPodDetector.shared.connected.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(L.syncGuideTitle)
        .popover(isPresented: $open, arrowEdge: .top) { SyncGuideView(store: store) }
    }
}

struct SyncGuideView: View {
    @Bindable var store: Store

    var body: some View {
        let playlist = store.model.playlistName
        let connected = IPodDetector.shared.connected
        VStack(alignment: .leading, spacing: 12) {
            Text(L.syncGuideTitle).font(.system(size: 14, weight: .semibold))
            if !connected.isEmpty {
                Label(L.syncConnected(connected.map(\.title).joined(separator: ", ")), systemImage: "cable.connector")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, L.syncStep1)
                step(2, L.syncStep2(playlist))
                step(3, L.syncStep3(playlist))
                step(4, L.syncStep4)
            }
            Text(L.syncNote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    // Finder не даёт открыть страницу синхронизации напрямую — открываем окно Finder,
                    // iPod виден в боковой панели в разделе «Места».
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
                } label: {
                    Label(L.syncOpenFinder, systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

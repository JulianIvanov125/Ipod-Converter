import Foundation

/// Версия программы. На Mac — из Info.plist; на Linux и Windows Info.plist в программе нет,
/// поэтому номер вшит константой — release.sh обновляет его вместе с Info.plist.
enum AppVersion {
    static let embedded = "1.5.3"

    static var current: String {
        #if os(macOS)
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? embedded
        #else
        embedded
        #endif
    }

    /// «1.3.10» > «1.3.9».
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// Только Linux: на Windows окно обновляется само (windows/WinUI/Updater.cs), а FoundationNetworking тянет curl.lib,
// которого нет в статическом SDK Swift для Windows — движок с -static-stdlib не линкуется.
#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Последний релиз на GitHub — для Linux (на Mac — Updater.swift, на Windows — Updater.cs окна).
/// Контрольную сумму берём из поля digest в API: файл .sha256 не качаем (не растёт счётчик загрузок).
struct ReleaseInfo {
    struct Asset {
        let name: String
        let url: URL
        let sha256: String?
    }
    let version: String
    let notes: String
    let page: URL
    let assets: [Asset]

    func asset(where match: (String) -> Bool) -> Asset? { assets.first { match($0.name) } }
}

enum ReleaseCheck {
    static let repo = "JulianIvanov125/Ipod-Converter"

    /// Адрес API можно подменить переменной IPODCONVERTER_RELEASE_URL (проверка на фальшивом релизе).
    static var apiURL: URL {
        if let s = ProcessInfo.processInfo.environment["IPODCONVERTER_RELEASE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    static func fetchLatest() async throws -> ReleaseInfo {
        var req = URLRequest(url: apiURL, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iPodConverter", forHTTPHeaderField: "User-Agent")
        let data = try await fetch(req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw NSError(domain: "iPodConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected answer from GitHub"])
        }
        let assets = ((j["assets"] as? [[String: Any]]) ?? []).compactMap { a -> ReleaseInfo.Asset? in
            guard let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let digest = (a["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
            return .init(name: name, url: url, sha256: digest)
        }
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           notes: j["body"] as? String ?? "", page: page, assets: assets)
    }

    /// GET без async-API URLSession (на Linux его нет в старых Foundation) — через completion handler.
    static func fetch(_ req: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err { cont.resume(throwing: err); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, (200..<300).contains(code) || resp?.url?.isFileURL == true else {
                    cont.resume(throwing: NSError(domain: "iPodConverter", code: code,
                                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))
                    return
                }
                cont.resume(returning: data)
            }.resume()
        }
    }

    /// Скачать файл во временную папку.
    static func download(_ url: URL, to file: URL) async throws {
        let data = try await fetch(URLRequest(url: url, timeoutInterval: 600))
        try data.write(to: file)
    }
}
#endif

#if os(macOS)
import Foundation
import Network

/// Крошечный HTTP-сервер только на 127.0.0.1 для просмотра видео, которое AVPlayer не открывает сам
/// (MKV, AVI…). ffmpeg переупаковывает такой файл в HLS по кусочкам, и смотреть можно сразу,
/// не дожидаясь копии всего фильма. HLS AVPlayer играет только по http, не из файла — поэтому сервер.
/// Отдаёт файлы только из временной папки предпросмотра.
final class PreviewServer: @unchecked Sendable {
    static let shared = PreviewServer()
    let root: URL
    private let queue = DispatchQueue(label: "iPodConverter.preview-http")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var waiting: [CheckedContinuation<UInt16?, Never>] = []

    private init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iPodConverter/preview", isDirectory: true).standardizedFileURL
    }

    /// http-адрес файла из папки предпросмотра; nil — сервер не поднялся.
    func url(for file: URL) async -> URL? {
        let base = root.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base), let port = await start() else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Int(port)
        c.path = "/" + path.dropFirst(base.count)
        return c.url
    }

    private func start() async -> UInt16? {
        await withCheckedContinuation { cont in
            queue.async {
                if self.port != 0 { cont.resume(returning: self.port); return }
                self.waiting.append(cont)
                guard self.listener == nil else { return }
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                guard let l = try? NWListener(using: params) else { self.finishStart(nil); return }
                l.newConnectionHandler = { [weak self] c in self?.serve(c) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = l.port?.rawValue ?? 0
                        self.finishStart(self.port == 0 ? nil : self.port)
                    case .failed, .cancelled:
                        self.listener = nil
                        self.port = 0
                        self.finishStart(nil)
                    default: break
                    }
                }
                self.listener = l
                l.start(queue: self.queue)
            }
        }
    }

    private func finishStart(_ port: UInt16?) {
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: port) }
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let parts = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(c, "405 Method Not Allowed", Data(), type: "text/plain")
        }
        let raw = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        let rel = raw.removingPercentEncoding ?? ""
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard !rel.contains(".."), file.path.hasPrefix(root.path + "/"),
              var data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return send(c, "404 Not Found", Data(), type: "text/plain")
        }
        // Пока поток готовится, AVPlayer считает его трансляцией и начинает с «живого края» —
        // пропуская начало. EXT-X-START велит начинать с самого начала.
        if file.pathExtension.lowercased() == "m3u8", var text = String(data: data, encoding: .utf8),
           !text.contains("#EXT-X-START"), let r = text.range(of: "#EXTM3U\n") {
            text.insert(contentsOf: "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n", at: r.upperBound)
            data = Data(text.utf8)
        }
        let type: String
        switch file.pathExtension.lowercased() {
        case "m3u8": type = "application/vnd.apple.mpegurl"
        case "m4s", "mp4": type = "video/mp4"
        default: type = "application/octet-stream"
        }
        send(c, "200 OK", data, type: type, headOnly: parts[0] == "HEAD")
    }

    private func send(_ c: NWConnection, _ status: String, _ body: Data, type: String, headOnly: Bool = false) {
        var out = Data(("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                        + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8)
        if !headOnly { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
#endif

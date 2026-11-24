#if os(Linux)
import CGtk
import Foundation

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// Колбэки GTK → Swift. В C уходит номер замыкания (как указатель), C вызывает общий обработчик.
@MainActor
enum Callbacks {
    static var plain: [Int: () -> Void] = [:]
    static var paths: [Int: (once: Bool, fn: ([String]) -> Void)] = [:]
    /// Колбэки строк списка: сбрасываются при каждой перестройке списка.
    static var rowIDs: [Int] = []
    private static var next = 1

    static func id(_ f: @escaping () -> Void, row: Bool = false) -> UnsafeMutableRawPointer {
        let n = next; next += 1
        plain[n] = f
        if row { rowIDs.append(n) }
        return UnsafeMutableRawPointer(bitPattern: n)!
    }

    /// once — для диалога (отвечает один раз), иначе — для перетаскивания (много раз).
    static func pathsID(once: Bool = true, _ f: @escaping ([String]) -> Void) -> UnsafeMutableRawPointer {
        let n = next; next += 1
        paths[n] = (once, f)
        return UnsafeMutableRawPointer(bitPattern: n)!
    }

    static func clearRows() {
        for n in rowIDs { plain[n] = nil }
        rowIDs = []
    }
}

private let runPlain: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    let n = Int(bitPattern: data)
    MainActor.assumeIsolated { Callbacks.plain[n]?() }
}

private let runPaths: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { text, data in
    let n = Int(bitPattern: data)
    let s = text.map { String(cString: $0) } ?? ""
    let list = s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    MainActor.assumeIsolated {
        guard let h = Callbacks.paths[n] else { return }
        if h.once { Callbacks.paths[n] = nil }
        h.fn(list)
    }
}

@MainActor
private func on(_ w: UnsafeMutableRawPointer?, _ signal: String, row: Bool = false, _ f: @escaping () -> Void) {
    cg_on(w, signal, runPlain, Callbacks.id(f, row: row))
}

@MainActor
private func strings(_ items: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Widget?) -> Widget? {
    let c = items.map { strdup($0) }
    defer { c.forEach { free($0) } }
    var arr: [UnsafePointer<CChar>?] = c.map { UnsafePointer($0) }
    arr.append(nil)
    return arr.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Окно Linux-версии на GTK4 + libadwaita.
@MainActor
final class LinuxWindow {
    enum Scope { case all, duplicates }

    let engine = LinuxEngine()
    private var app: UnsafeMutablePointer<GtkApplication>!
    private var window: Widget!
    private var toasts: Widget!
    private var list: Widget!
    private var listScroll: Widget!
    private var empty: Widget!
    private var ipodDrop: Widget!
    private var qualityDrop: Widget!
    private var qualityHint: Widget!
    private var outButton: Widget!
    private var allToggle: Widget!
    private var dupToggle: Widget!
    private var status: Widget!
    private var convertButton: Widget!
    private var clearButton: Widget!
    private var banner: Widget!
    /// Плеер не смог (нет GStreamer или кодека) — открываем системным плеером.
    private var playFallback: UnsafeMutableRawPointer!
    private var updating = false
    private var scope: Scope = .all

    /// Строки списка: чтобы прогресс обновлять без перестройки.
    private var rowOrder: [String] = []
    private var rowStatus: [UUID: Widget] = [:]
    private var rowProgress: [UUID: Widget] = [:]
    private var refreshScheduled = false
    /// Список качества меняем сами — его «выбор изменился» не считать выбором пользователя.
    private var updatingQuality = false

    func run() {
        app = cg_app_new("io.github.ipodconverter.linux")
        on(app, "activate") { [unowned self] in self.build() }
        cg_app_start(app)
        // GLib-цикл крутим из главного RunLoop: так работают и GTK, и async/await Swift на главном потоке.
        Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            while cg_iterate() != 0 {}
        }
        RunLoop.main.run()
    }

    // MARK: Построение окна

    private func build() {
        window = cg_window(app, "iPod Converter", 980, 700)
        cg_on_close(window, runPlain, Callbacks.id { LinuxEngine.save(); exit(0) })

        let tv = cg_toolbar_view()!
        let header = cg_header()!
        let addFiles = cg_button(L.t("Add files", "Добавить файлы", "Додати файли", "Дадаць файлы"))!
        cg_css_class(addFiles, "suggested-action")
        on(addFiles, "clicked") { [unowned self] in self.choose(folders: false) }
        let addFolder = cg_icon_button("folder-new-symbolic")!
        cg_tooltip(addFolder, L.t("Add a folder", "Добавить папку", "Додати теку", "Дадаць тэчку"))
        on(addFolder, "clicked") { [unowned self] in self.choose(folders: true) }
        cg_header_start(header, addFiles)
        cg_header_start(header, addFolder)
        clearButton = cg_button(L.clearList)
        cg_css_class(clearButton, "flat")
        on(clearButton, "clicked") { [unowned self] in self.engine.clear() }
        cg_header_end(header, clearButton)
        let updButton = cg_icon_button("software-update-available-symbolic")!
        cg_css_class(updButton, "flat")
        cg_tooltip(updButton, L.t("Check for updates", "Проверить обновления", "Перевірити оновлення", "Праверыць абнаўленні"))
        on(updButton, "clicked") { [unowned self] in self.checkForUpdates(userInitiated: true) }
        cg_header_end(header, updButton)
        cg_toolbar_top(tv, header)

        // Плашка «Доступна версия …» — появляется, когда на GitHub есть версия новее.
        banner = cg_banner("")
        on(banner, "button-clicked") { [unowned self] in self.installUpdate() }
        cg_toolbar_top(tv, banner)

        // Панель: iPod, качество, папка, фильтр
        let bar = cg_box(0, 10)!
        cg_margins(bar, 12, 16, 6, 16)
        bar.appendLabel(L.t("iPod:", "iPod:", "iPod:", "iPod:"))
        ipodDrop = strings(IPodModel.allCases.map(\.title)) { cg_dropdown($0) }
        cg_dropdown_set(ipodDrop, UInt32(IPodModel.allCases.firstIndex(of: engine.model) ?? 0))
        cg_on3(ipodDrop, "notify::selected", runPlain, Callbacks.id { [unowned self] in
            let i = Int(cg_dropdown_get(self.ipodDrop))
            if IPodModel.allCases.indices.contains(i) { self.engine.model = IPodModel.allCases[i] }
            self.updateQuality()
            self.refresh(rebuild: true)
        })
        cg_append(bar, ipodDrop)
        qualityDrop = cg_dropdown(nil)
        cg_on3(qualityDrop, "notify::selected", runPlain, Callbacks.id { [unowned self] in
            guard !self.updatingQuality else { return }
            let maxOn = cg_dropdown_get(self.qualityDrop) == 1
            if self.engine.model.supportsMax && self.engine.maxQuality != maxOn {
                self.engine.maxQuality = maxOn
                self.refresh(rebuild: true)
            }
        })
        cg_append(bar, qualityDrop)
        qualityHint = cg_label("")
        cg_css_class(qualityHint, "dim-label")
        cg_append(bar, qualityHint)
        let spacer = cg_box(0, 0)!
        cg_hexpand(spacer, 1)
        cg_append(bar, spacer)
        outButton = cg_button("")
        cg_tooltip(outButton, L.t("Where to save converted files", "Куда сохранять готовые файлы",
                                  "Куди зберігати готові файли", "Куды захоўваць гатовыя файлы"))
        on(outButton, "clicked") { [unowned self] in self.chooseOutput() }
        cg_append(bar, outButton)
        cg_toolbar_top(tv, bar)

        let scopeBar = cg_box(0, 0)!
        cg_css_class(scopeBar, "linked")
        cg_margins(scopeBar, 4, 16, 6, 16)
        allToggle = cg_toggle("")
        dupToggle = cg_toggle("")
        cg_toggle_group(dupToggle, allToggle)
        cg_toggle_set(allToggle, 1)
        on(allToggle, "toggled") { [unowned self] in
            if cg_toggle_get(self.allToggle) != 0 { self.scope = .all; self.refresh(rebuild: true) }
        }
        on(dupToggle, "toggled") { [unowned self] in
            if cg_toggle_get(self.dupToggle) != 0 { self.scope = .duplicates; self.refresh(rebuild: true) }
        }
        cg_append(scopeBar, allToggle)
        cg_append(scopeBar, dupToggle)
        cg_toolbar_top(tv, scopeBar)

        // Список и пустой экран
        let content = cg_box(1, 0)!
        list = cg_listbox()
        let column = cg_box(1, 0)!
        cg_margins(column, 6, 16, 16, 16)
        cg_append(column, list)
        listScroll = cg_scrolled(column)
        empty = cg_status_page("media-optical-symbolic",
                               L.t("Drop music or videos here", "Перетащите сюда музыку или видео",
                                   "Перетягніть сюди музику або відео", "Перацягніце сюды музыку або відэа"),
                               L.t("or press “Add files”. Files are converted for the chosen iPod into the output folder; copy them to the iPod with Rhythmbox, gtkpod or Strawberry.",
                                   "или нажмите «Добавить файлы». Файлы конвертируются под выбранный iPod в папку вывода; на iPod их переносит Rhythmbox, gtkpod или Strawberry.",
                                   "або натисніть «Додати файли». Файли конвертуються під вибраний iPod у теку виводу; на iPod їх переносить Rhythmbox, gtkpod або Strawberry.",
                                   "або націсніце «Дадаць файлы». Файлы канвертуюцца пад абраны iPod у тэчку вываду; на iPod іх пераносіць Rhythmbox, gtkpod ці Strawberry."))
        cg_append(content, empty)
        cg_append(content, listScroll)
        toasts = cg_toast_overlay(content)
        cg_toolbar_content(tv, toasts)
        cg_on_drop_files(window, runPaths, Callbacks.pathsID(once: false) { [unowned self] p in self.addPaths(p) })

        // Низ: статус и кнопка
        let bottom = cg_box(0, 10)!
        cg_margins(bottom, 8, 16, 8, 16)
        status = cg_label("")
        cg_hexpand(status, 1)
        cg_label_ellipsize(status)
        cg_css_class(status, "dim-label")
        cg_append(bottom, status)
        convertButton = cg_button(L.convert)
        cg_css_class(convertButton, "suggested-action")
        on(convertButton, "clicked") { [unowned self] in self.convertOrStop() }
        cg_append(bottom, convertButton)
        cg_toolbar_bottom(tv, bottom)

        cg_window_set_content(window, tv)
        playFallback = Callbacks.pathsID(once: false) { [unowned self] p in
            guard let path = p.first else { return }
            LinuxUpdater.open(URL(fileURLWithPath: path))
            cg_toast(self.toasts, L.t("Opened in your system player", "Открыто в системном плеере",
                                      "Відкрито в системному програвачі", "Адкрыта ў сістэмным прайгравальніку"))
        }
        engine.onChange = { [unowned self] in self.scheduleRefresh() }
        LinuxUpdater.shared.onChange = { [unowned self] in self.updateBanner() }
        LinuxUpdater.shared.checkOnLaunch()
        updateQuality()
        refresh(rebuild: true)
        cg_present(window)
    }

    // MARK: Обновление

    private func checkForUpdates(userInitiated: Bool) {
        Task { @MainActor in
            let r = await LinuxUpdater.shared.check()
            if userInitiated && r == nil {
                cg_toast(toasts, L.t("You have the latest version (\(AppVersion.current))", "У вас последняя версия (\(AppVersion.current))",
                                     "У вас остання версія (\(AppVersion.current))", "У вас апошняя версія (\(AppVersion.current))"))
            }
        }
    }

    private func updateBanner() {
        guard let r = LinuxUpdater.shared.available else { cg_banner_reveal(banner, 0); return }
        cg_banner_title(banner, L.t("iPod Converter \(r.version) is available (you have \(AppVersion.current))",
                                    "Доступна версия \(r.version) (у вас \(AppVersion.current))",
                                    "Доступна версія \(r.version) (у вас \(AppVersion.current))",
                                    "Даступная версія \(r.version) (у вас \(AppVersion.current))"))
        let label: String
        switch LinuxUpdater.kind {
        case .userLocal: label = L.t("Update and restart", "Обновить и перезапустить", "Оновити й перезапустити", "Абнавіць і перазапусціць")
        case .deb: label = L.t("Download and install", "Скачать и установить", "Завантажити й встановити", "Спампаваць і ўсталяваць")
        case .other: label = L.t("Open the download page", "Открыть страницу загрузки", "Відкрити сторінку завантаження", "Адкрыць старонку загрузкі")
        }
        cg_banner_button(banner, label)
        cg_banner_reveal(banner, 1)
    }

    private func installUpdate() {
        guard let r = LinuxUpdater.shared.available, !updating else { return }
        updating = true
        cg_banner_button(banner, L.t("Downloading…", "Загрузка…", "Завантаження…", "Загрузка…"))
        Task { @MainActor in
            do {
                switch try await LinuxUpdater.shared.install(r) {
                case .restarted: break
                case .openedInstaller:
                    cg_toast(toasts, L.t("The installer opened — confirm the update there, then start iPod Converter again",
                                         "Открылся установщик — подтвердите обновление и запустите iPod Converter заново",
                                         "Відкрився інсталятор — підтвердьте оновлення й запустіть iPod Converter знову",
                                         "Адкрыўся ўсталёўшчык — пацвердзіце абнаўленне і запусціце iPod Converter зноў"))
                case .openedPage: break
                }
            } catch {
                cg_toast(toasts, error.localizedDescription)
                AppLog.error("Update failed: \(error.localizedDescription)")
            }
            updating = false
            updateBanner()
        }
    }

    // MARK: Действия

    private func play(_ url: URL, title: String, video: Bool) {
        cg_play_file(window, url.path, title, video ? 1 : 0, runPaths, playFallback)
    }

    private func choose(folders: Bool) {
        let title = folders ? L.t("Add folders", "Добавить папки", "Додати теки", "Дадаць тэчкі")
            : L.t("Add music or videos", "Добавить музыку или видео", "Додати музику або відео", "Дадаць музыку або відэа")
        cg_choose(window, folders ? 1 : 0, title, runPaths, Callbacks.pathsID { [unowned self] p in self.addPaths(p) })
    }

    private func addPaths(_ p: [String]) {
        guard !p.isEmpty else { return }
        engine.add(p.map { URL(fileURLWithPath: $0) })
    }

    private func chooseOutput() {
        cg_choose_folder(window, L.t("Output folder", "Папка для готовых файлов", "Тека для готових файлів", "Тэчка для гатовых файлаў"),
                         runPaths, Callbacks.pathsID { [unowned self] p in
            guard let path = p.first else { return }
            self.engine.outputRoot = URL(fileURLWithPath: path)
            self.refresh(rebuild: false)
        })
    }

    private func convertOrStop() {
        if engine.running { engine.cancel(); return }
        Task { @MainActor in
            let r = await engine.convertAll()
            let text = r.failed == 0
                ? L.t("Done: \(r.done)", "Готово: \(r.done)", "Готово: \(r.done)", "Гатова: \(r.done)")
                : L.t("Done: \(r.done), failed: \(r.failed)", "Готово: \(r.done), ошибок: \(r.failed)",
                      "Готово: \(r.done), помилок: \(r.failed)", "Гатова: \(r.done), памылак: \(r.failed)")
            cg_toast(toasts, text)
        }
    }

    private func updateQuality() {
        let m = engine.model
        let st = m.settings(max: false), mx = m.settings(max: true)
        var items = ["\(L.standard) · \(st.w)×\(st.h)"]
        if m.supportsMax { items.append("\(L.maximum) · \(mx.w)×\(mx.h)") }
        updatingQuality = true
        _ = strings(items) { cg_dropdown_items(qualityDrop, $0); return nil }
        cg_dropdown_set(qualityDrop, m.supportsMax && engine.maxQuality ? 1 : 0)
        updatingQuality = false
        cg_sensitive(qualityDrop, m.supportsMax ? 1 : 0)
        let s = engine.settings
        cg_label_set(qualityHint, "H.264 \(s.profileName) · \(Fmt.kbps(s.videoKbps))")
    }

    // MARK: Список

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh(rebuild: false)
            }
        }
    }

    private struct Row {
        let id: UUID
        let title: String
        let detail: String
        let state: LinuxItemState
        let cover: URL?
        let isVideo: Bool
        var url: URL? = nil
        /// «было → стало» после конвертации (битрейт, размер; у видео ещё разрешение).
        var change: String = ""
        var dup: (keeper: Bool, groupStart: Bool)?
        /// Меняется — строку надо перестроить (прочитали файл, появилась обложка, сменилась роль дубля).
        var key: String { "\(id)|\(title)|\(detail)|\(change)|\(cover?.path ?? "")|\(dup.map { "\($0.keeper)" } ?? "")|\(state.isBusy)" }
    }

    private func rows() -> [Row] {
        switch scope {
        case .all:
            let ts = engine.tracks.map { t in
                var r = Row(id: t.id, title: t.info?.title.map { "\(t.info?.artist ?? "") — \($0)" } ?? t.url.lastPathComponent,
                    detail: t.info.map { "\($0.codec.uppercased()) · \($0.sampleRate / 1000) kHz · \(Fmt.duration($0.duration))" } ?? "",
                    state: t.state, cover: nil, isVideo: false)
                r.url = t.url
                if let a = t.info, let b = t.outInfo {
                    r.change = Self.change(a.bitrate, b.bitrate, a.fileSize, b.fileSize)
                }
                return r
            }
            let vs = engine.videos.map { v in
                var r = Row(id: v.id, title: v.meta.map { $0.artist.isEmpty ? $0.title : "\($0.artist) — \($0.title)" } ?? v.url.lastPathComponent,
                    detail: videoDetail(v), state: v.state, cover: v.cover, isVideo: true)
                r.url = v.url
                if let a = v.info, let b = v.outInfo {
                    r.change = "\(a.displayWidth)×\(a.displayHeight) → \(b.displayWidth)×\(b.displayHeight) · "
                        + Self.change(a.videoBitrate, b.videoBitrate, a.fileSize, b.fileSize)
                }
                return r
            }
            return ts + vs
        case .duplicates:
            var out: [Row] = []
            for g in engine.videoDuplicateGroups {
                for (i, v) in g.all.enumerated() {
                    var r = Row(id: v.id, title: v.meta.map { $0.artist.isEmpty ? $0.title : "\($0.artist) — \($0.title)" } ?? v.url.lastPathComponent,
                                detail: videoDetail(v) + "\n" + v.url.path, state: v.state, cover: v.cover, isVideo: true)
                    r.dup = (v.id == g.keeper.id, i == 0)
                    r.url = v.url
                    out.append(r)
                }
            }
            return out
        }
    }

    /// «926 → 256 кбит/с · 24,6 → 6,8 МБ».
    static func change(_ br0: Int?, _ br1: Int?, _ s0: Int64, _ s1: Int64) -> String {
        var parts: [String] = []
        if let a = br0, let b = br1 { parts.append("\(a / 1000) → \(b / 1000) \(L.kbps)") }
        parts.append("\(Fmt.bytes(s0)) → \(Fmt.bytes(s1))")
        return parts.joined(separator: " · ")
    }

    private func videoDetail(_ v: LinuxVideo) -> String {
        guard let i = v.info else { return v.url.lastPathComponent }
        let out = engine.settings.outputSize(for: i)
        return "\(i.displayWidth)×\(i.displayHeight) \(i.videoCodec.uppercased()) · \(Fmt.duration(i.duration)) → \(out.w)×\(out.h)"
    }

    private func stateText(_ s: LinuxItemState) -> String {
        switch s {
        case .loading: L.t("Reading…", "Читаю…", "Читаю…", "Чытаю…")
        case .ready: L.t("Ready to convert", "Готово к конвертации", "Готово до конвертації", "Гатова да канвертацыі")
        case .queued: L.t("In queue", "В очереди", "У черзі", "У чарзе")
        case .converting(let p): "\(Int(p * 100))%"
        case .done(let u): "✓ " + u.lastPathComponent
        case .kept(let u): "✓ " + L.t("as is", "как есть", "як є", "як ёсць") + " · " + u.lastPathComponent
        case .failed(let e): "✗ " + e
        }
    }

    private func refresh(rebuild force: Bool) {
        guard list != nil else { return }
        let rs = rows()
        let dupCount = engine.videoDuplicateGroups.reduce(0) { $0 + $1.extras.count }
        cg_button_set_label(allToggle, L.t("All (\(engine.tracks.count + engine.videos.count))", "Все (\(engine.tracks.count + engine.videos.count))",
                                           "Усі (\(engine.tracks.count + engine.videos.count))", "Усе (\(engine.tracks.count + engine.videos.count))"))
        cg_button_set_label(dupToggle, L.scopeDuplicates(dupCount))
        cg_button_set_label(outButton, tilde(engine.outputRoot.path))
        let hasItems = !engine.tracks.isEmpty || !engine.videos.isEmpty
        cg_visible(empty, hasItems ? 0 : 1)
        cg_visible(listScroll, hasItems ? 1 : 0)
        cg_sensitive(clearButton, hasItems && !engine.running ? 1 : 0)
        cg_sensitive(ipodDrop, engine.running ? 0 : 1)
        cg_sensitive(qualityDrop, !engine.running && engine.model.supportsMax ? 1 : 0)

        let pend = engine.pending
        let n = pend.videos.count + pend.tracks.count
        cg_button_set_label(convertButton, engine.running ? L.stop : L.convertN(n))
        cg_sensitive(convertButton, engine.running || n > 0 ? 1 : 0)
        if engine.running { cg_css_remove(convertButton, "suggested-action"); cg_css_class(convertButton, "destructive-action") }
        else { cg_css_remove(convertButton, "destructive-action"); cg_css_class(convertButton, "suggested-action") }
        let s = engine.settings
        cg_label_set(status, "\(engine.model.title) · \(s.w)×\(s.h) H.264 \(s.profileName) → "
                     + tilde(engine.outputRoot.path))

        if force || rs.map(\.key) != rowOrder {
            rebuildRows(rs)
        } else {
            for r in rs {
                if let l = rowStatus[r.id] { cg_label_set(l, stateText(r.state)) }
                if let p = rowProgress[r.id] {
                    if case .converting(let f) = r.state { cg_visible(p, 1); cg_progress_set(p, f) } else { cg_visible(p, 0) }
                }
            }
        }
    }

    private func rebuildRows(_ rs: [Row]) {
        cg_listbox_clear(list)
        Callbacks.clearRows()
        rowStatus = [:]
        rowProgress = [:]
        rowOrder = rs.map(\.key)
        if rs.isEmpty && scope == .duplicates {
            let l = cg_label(L.dupNone)!
            cg_margins(l, 16, 16, 16, 16)
            cg_css_class(l, "dim-label")
            cg_listbox_append(list, l)
            return
        }
        for r in rs {
            let row = cg_box(0, 12)!
            cg_margins(row, 8, 12, 8, 12)
            if let d = r.dup {
                cg_append(row, cg_icon(d.keeper ? "emblem-ok-symbolic" : "edit-copy-symbolic", 16))
            } else {
                let c = cg_check()!
                let checked = r.isVideo ? engine.videos.first { $0.id == r.id }?.checked ?? true
                    : engine.tracks.first { $0.id == r.id }?.checked ?? true
                cg_check_set(c, checked ? 1 : 0)
                on(c, "toggled", row: true) { [unowned self] in
                    let on = cg_check_get(c) != 0
                    if let v = self.engine.videos.first(where: { $0.id == r.id }) { v.checked = on }
                    if let t = self.engine.tracks.first(where: { $0.id == r.id }) { t.checked = on }
                    self.refresh(rebuild: false)
                }
                cg_valign(c, 3)
                cg_append(row, c)
            }
            if let cover = r.cover {
                let pic = cg_image_file(cover.path, 45)!
                cg_append(row, pic)
            } else {
                cg_append(row, cg_icon(r.isVideo ? "video-x-generic-symbolic" : "audio-x-generic-symbolic", 32))
            }
            let text = cg_box(1, 2)!
            cg_hexpand(text, 1)
            let title = cg_label(r.title)!
            cg_label_ellipsize(title)
            cg_css_class(title, "heading")
            cg_append(text, title)
            let detail = cg_label(r.detail)!
            cg_label_ellipsize(detail)
            cg_css_class(detail, "dim-label")
            cg_css_class(detail, "caption")
            cg_append(text, detail)
            let st = cg_label(stateText(r.state) + (r.change.isEmpty ? "" : "   " + r.change))!
            cg_label_ellipsize(st)
            cg_css_class(st, "caption")
            cg_append(text, st)
            rowStatus[r.id] = st
            let p = cg_progress()!
            if case .converting(let f) = r.state { cg_progress_set(p, f) } else { cg_visible(p, 0) }
            cg_append(text, p)
            rowProgress[r.id] = p
            cg_append(row, text)

            // ▶ оригинал и, если уже есть, ▶ готовый файл — проверить картинку и звук до синхронизации.
            if let src = r.url {
                let play = cg_icon_button("media-playback-start-symbolic")!
                cg_css_class(play, "flat")
                cg_valign(play, 3)
                cg_tooltip(play, L.previewOriginal)
                on(play, "clicked", row: true) { [unowned self] in self.play(src, title: r.title, video: r.isVideo) }
                cg_append(row, play)
            }
            let result: URL? = {
                switch r.state { case .done(let u), .kept(let u): return u; default: return nil }
            }()
            if let out = result {
                let play = cg_button("▶ " + L.t("Converted", "Готовый", "Готовий", "Гатовы"))!
                cg_css_class(play, "flat")
                cg_valign(play, 3)
                cg_tooltip(play, out.path)
                on(play, "clicked", row: true) { [unowned self] in
                    self.play(out, title: r.title + " — " + L.t("converted", "готовый", "готовий", "гатовы"), video: r.isVideo)
                }
                cg_append(row, play)
            }

            if let d = r.dup {
                let badge = cg_label(d.keeper ? L.dupKeeper : L.dupCopy)!
                cg_css_class(badge, d.keeper ? "success" : "warning")
                cg_css_class(badge, "caption-heading")
                cg_valign(badge, 3)
                cg_append(row, badge)
                if !d.keeper {
                    let keep = cg_button(L.dupKeepThis)!
                    cg_css_class(keep, "flat")
                    cg_valign(keep, 3)
                    on(keep, "clicked", row: true) { [unowned self] in
                        if let v = self.engine.videos.first(where: { $0.id == r.id }) { self.engine.keepDuplicate(v) }
                    }
                    cg_append(row, keep)
                    let trash = cg_icon_button("user-trash-symbolic")!
                    cg_css_class(trash, "destructive-action")
                    cg_tooltip(trash, L.dupTrashOne)
                    cg_valign(trash, 3)
                    on(trash, "clicked", row: true) { [unowned self] in
                        guard let v = self.engine.videos.first(where: { $0.id == r.id }) else { return }
                        let res = self.engine.trashDuplicates([v])
                        cg_toast(self.toasts, res.failed.isEmpty ? L.dupTrashed(res.moved) : res.failed.joined(separator: "; "))
                    }
                    cg_append(row, trash)
                }
            } else if !r.state.isBusy {
                let remove = cg_icon_button("window-close-symbolic")!
                cg_css_class(remove, "flat")
                cg_valign(remove, 3)
                on(remove, "clicked", row: true) { [unowned self] in
                    if let v = self.engine.videos.first(where: { $0.id == r.id }) { self.engine.remove(video: v) }
                    if let t = self.engine.tracks.first(where: { $0.id == r.id }) { self.engine.remove(track: t) }
                }
                cg_append(row, remove)
            }
            cg_listbox_append(list, row)
        }
    }
}

private extension UnsafeMutablePointer where Pointee == GtkWidget {
    @MainActor func appendLabel(_ text: String) {
        let l = cg_label(text)!
        cg_append(self, l)
    }
}

enum LinuxApp {
    @MainActor static var window: LinuxWindow?
    static func run(files: [URL] = []) {
        MainActor.assumeIsolated {
            let w = LinuxWindow()
            window = w
            if !files.isEmpty { w.engine.add(files) }
            w.run()
        }
    }
}
#endif

#if os(Linux)
/// «/home/user/Videos» → «~/Videos».
func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
#endif

import AppKit
import Observation

struct ShelfItem: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Files dropped on the notch. Only paths are stored, the files are never copied.
@MainActor @Observable
final class Shelf: NSObject, NSSharingServiceDelegate {
    private(set) var items: [ShelfItem] = []
    var selection: Set<ShelfItem.ID> = []
    /// True while the AirDrop sheet is open, so the panel stays open.
    private(set) var isSharing = false
    /// The app that was frontmost before AirDrop activated us, re-activated afterwards.
    private var previousApp: NSRunningApplication?
    private var sharingTimeout: Task<Void, Never>?

    private let storeURL: URL

    init(storeURL: URL = Shelf.defaultStoreURL) {
        self.storeURL = storeURL
        super.init()
        load()
    }

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchHub/shelf.json")
    }

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    func add(_ urls: [URL]) {
        var seen = Set<String>()
        let new = urls.filter(\.isFileURL)
            .map { ShelfItem(path: $0.standardizedFileURL.path) }
            .filter { seen.insert($0.path).inserted }
        guard !new.isEmpty else { return }
        items.removeAll { item in new.contains(item) }
        items.insert(contentsOf: new, at: 0)
        save()
    }

    func remove(_ removed: [ShelfItem]) {
        items.removeAll { removed.contains($0) }
        selection.subtract(removed.map(\.id))
        save()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        save()
    }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func revealInFinder(_ shown: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(shown.map(\.url))
    }

    func airDrop(_ shared: [ShelfItem]) {
        airDrop(urls: shared.map(\.url))
    }

    func airDrop(urls: [URL]) {
        let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return }
        service.delegate = self
        isSharing = true
        // If the sheet never reports back, do not keep the panel pinned open forever.
        sharingTimeout?.cancel()
        sharingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.isSharing = false
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finishSharing() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        MainActor.assumeIsolated { finishSharing() }
    }

    private func finishSharing() {
        sharingTimeout?.cancel()
        isSharing = false
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        previousApp = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        if items.count != saved.count { save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
    }
}

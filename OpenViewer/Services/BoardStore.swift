import Foundation

/// An image placed on a board: where it sits, how big and how turned.
struct BoardItem: Codable, Hashable {
    let id: UUID
    /// The file, as a path key plus a bookmark for files outside the app.
    var path: String
    var bookmark: Data?
    var centerX: Double
    var centerY: Double
    /// Width on the board, in board points (height follows the image's proportions).
    var width: Double
    var rotation: Double
}

/// A free canvas of reference images (a moodboard). Later items are drawn on top.
struct Board: Codable, Hashable {
    let id: UUID
    var name: String
    var items: [BoardItem]
    var created: Date

    static let canvasSize = 12_000.0
    static var center: (x: Double, y: Double) { (canvasSize / 2, canvasSize / 2) }
}

/// Saved boards, in sidebar order. Main-thread API.
final class BoardStore {
    static let shared = BoardStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/boards.json"))

    static let didChange = Notification.Name("OpenViewer.boardsDidChange")

    private(set) var boards: [Board] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Board].self, from: data) {
            boards = stored
        }
    }

    func board(_ id: UUID) -> Board? { boards.first { $0.id == id } }

    @discardableResult
    func create(named name: String) -> Board {
        let board = Board(id: UUID(), name: name, items: [], created: Date())
        boards.append(board)
        save()
        return board
    }

    func update(_ board: Board, notify: Bool = false) {
        guard let index = boards.firstIndex(where: { $0.id == board.id }) else { return }
        boards[index] = board
        save(notify: notify)
    }

    func remove(_ id: UUID) {
        boards.removeAll { $0.id == id }
        save()
    }

    func reorder(_ ids: [UUID]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        boards.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        save()
    }

    /// Adds images to a board in a loose grid to the right of what is already there.
    func add(_ urls: [URL], to id: UUID) {
        guard var board = board(id), !urls.isEmpty else { return }
        let width = 600.0, gap = 60.0
        let columns = max(1, Int(Double(urls.count).squareRoot().rounded(.up)))
        let startX = (board.items.map { $0.centerX + $0.width / 2 }.max() ?? Board.center.x - width) + gap + width / 2
        let startY = board.items.isEmpty ? Board.center.y : board.items.map(\.centerY).min() ?? Board.center.y
        for (index, url) in urls.enumerated() {
            let column = index % columns, row = index / columns
            board.items.append(BoardItem(
                id: UUID(), path: FavoritesStore.key(url),
                bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                centerX: startX + Double(column) * (width + gap), centerY: startY + Double(row) * (width + gap),
                width: width, rotation: 0))
        }
        update(board, notify: true)
    }

    func resolve(_ item: BoardItem) -> URL {
        var stale = false
        if let bookmark = item.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return PathKey.url(item.path)
    }

    private func save(notify: Bool = true) {
        if let fileURL, let data = try? JSONEncoder().encode(boards) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        if notify { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

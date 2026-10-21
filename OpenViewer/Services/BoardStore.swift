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

/// Tidy layouts for a board. Images keep their reading order (top to bottom, then left to
/// right, as they are now), lose any rotation, and the result is centred where the board was.
enum BoardArrangement: CaseIterable {
    /// Equal square cells in a centred grid; each image fits its cell, centred.
    case grid
    /// Rows of equal height that share one width, keeping each image's proportions (like the
    /// image grid); the last row keeps the same height and is centred.
    case rows

    var title: String { self == .grid ? "Grid" : "Rows" }
    var subtitle: String { self == .grid ? "Same-size cells, evenly spaced" : "Equal rows, proportions kept" }
    var symbol: String { self == .grid ? "square.grid.3x3" : "rectangle.split.3x1" }

    static let cell = 600.0
    static let gap = 60.0

    /// `aspects`: height / width of each image (1 when unknown). Returns the items, in their
    /// original (layer) order, with new positions and sizes.
    func apply(to items: [BoardItem], aspects: [UUID: Double]) -> [BoardItem] {
        guard !items.isEmpty else { return items }
        let aspect = { (item: BoardItem) in max(aspects[item.id] ?? 1, 0.01) }
        let ordered = Self.readingOrder(items, aspect: aspect)
        let columns = max(1, Int((Double(items.count) * 1.5).squareRoot().rounded(.up)))
        var frames: [UUID: CGRect] = [:]

        switch self {
        case .grid:
            for (index, item) in ordered.enumerated() {
                let column = index % columns, row = index / columns
                // In the last, shorter row the cells are centred.
                let inRow = min(columns, ordered.count - row * columns)
                let offset = Double(columns - inRow) * (Self.cell + Self.gap) / 2
                let a = aspect(item)
                let width = a <= 1 ? Self.cell : Self.cell / a
                let cellX = offset + Double(column) * (Self.cell + Self.gap)
                let cellY = Double(row) * (Self.cell + Self.gap)
                frames[item.id] = CGRect(x: cellX + (Self.cell - width) / 2, y: cellY + (Self.cell - width * a) / 2,
                                         width: width, height: width * a)
            }
        case .rows:
            let rowWidth = Double(columns) * Self.cell + Double(columns - 1) * Self.gap
            let targetHeight = Self.cell * 0.75
            var y = 0.0
            var start = 0
            func place(_ range: Range<Int>, height: Double) {
                let total = ordered[range].reduce(0) { $0 + height / aspect($1) } + Double(range.count - 1) * Self.gap
                var x = (rowWidth - total) / 2
                for item in ordered[range] {
                    let width = height / aspect(item)
                    frames[item.id] = CGRect(x: x, y: y, width: width, height: height)
                    x += width + Self.gap
                }
                y += height + Self.gap
            }
            var ratioSum = 0.0
            for index in ordered.indices {
                ratioSum += 1 / aspect(ordered[index])
                let gaps = Double(index - start) * Self.gap
                if ratioSum * targetHeight + gaps >= rowWidth {
                    place(start..<(index + 1), height: (rowWidth - gaps) / ratioSum)
                    start = index + 1
                    ratioSum = 0
                }
            }
            if start < ordered.count { place(start..<ordered.count, height: targetHeight) }
        }

        // Centre the new layout where the old one was.
        let oldCenter = Self.center(of: items.map { CGRect(x: $0.centerX - $0.width / 2, y: $0.centerY - $0.width * aspect($0) / 2,
                                                           width: $0.width, height: $0.width * aspect($0)) })
        let newCenter = Self.center(of: Array(frames.values))
        let dx = oldCenter.x - newCenter.x, dy = oldCenter.y - newCenter.y
        return items.map { item in
            guard let frame = frames[item.id] else { return item }
            var item = item
            item.centerX = frame.midX + dx
            item.centerY = frame.midY + dy
            item.width = frame.width
            item.rotation = 0
            return item
        }
    }

    /// Top to bottom, then left to right: items whose centres are within half a typical image
    /// height of each other count as one row.
    static func readingOrder(_ items: [BoardItem], aspect: (BoardItem) -> Double) -> [BoardItem] {
        let heights = items.map { $0.width * aspect($0) }.sorted()
        let tolerance = heights[heights.count / 2] / 2
        var rows: [[BoardItem]] = []
        for item in items.sorted(by: { $0.centerY < $1.centerY }) {
            if let first = rows.last?.first, item.centerY - first.centerY <= tolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.flatMap { $0.sorted { $0.centerX < $1.centerX } }
    }

    private static func center(of frames: [CGRect]) -> CGPoint {
        let union = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
        return CGPoint(x: union.midX, y: union.midY)
    }
}

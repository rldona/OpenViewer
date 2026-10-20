import Foundation

/// Anything that can be listed in the browser and sorted.
protocol Listable {
    var url: URL { get }
    var name: String { get }
    var modified: Date { get }
    var size: Int { get }
}

struct ImageItem: Listable, Hashable {
    let url: URL
    let name: String
    let size: Int
    let modified: Date

    init(url: URL, size: Int, modified: Date) {
        self.url = url
        self.name = url.lastPathComponent
        self.size = size
        self.modified = modified
    }
}

struct FolderItem: Listable, Hashable {
    let url: URL
    let name: String
    let modified: Date
    var size: Int { 0 }

    init(url: URL, modified: Date) {
        self.url = url
        self.name = url.lastPathComponent
        self.modified = modified
    }
}

enum SortKey: String, CaseIterable {
    case name, date, size

    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date Modified"
        case .size: return "Size"
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey
    var ascending: Bool
}

extension Array where Element: Listable {
    /// Sorts with Finder-like natural ordering ("img2" < "img10").
    /// `byPath` keeps images of the same folder together in recursive mode.
    func sorted(by order: SortOrder, byPath: Bool = false) -> [Element] {
        func nameLess(_ a: Element, _ b: Element) -> Bool {
            let l = byPath ? a.url.path : a.name
            let r = byPath ? b.url.path : b.name
            return l.localizedStandardCompare(r) == .orderedAscending
        }
        let ascending: [Element]
        switch order.key {
        case .name:
            ascending = sorted(by: nameLess)
        case .date:
            ascending = sorted { $0.modified == $1.modified ? nameLess($0, $1) : $0.modified < $1.modified }
        case .size:
            ascending = sorted { $0.size == $1.size ? nameLess($0, $1) : $0.size < $1.size }
        }
        return order.ascending ? ascending : ascending.reversed()
    }
}

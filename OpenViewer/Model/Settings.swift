import Foundation

/// Small persisted user preferences.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var sortOrder: SortOrder {
        get {
            let key = SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name
            let ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
            return SortOrder(key: key, ascending: ascending)
        }
        set {
            defaults.set(newValue.key.rawValue, forKey: "sortKey")
            defaults.set(newValue.ascending, forKey: "sortAscending")
        }
    }

    /// Index into `BrowserViewController.gridLevels`.
    static var gridLevel: Int {
        get { defaults.object(forKey: "gridLevel") as? Int ?? 2 }
        set { defaults.set(newValue, forKey: "gridLevel") }
    }

    static var includeSubfolders: Bool {
        get { defaults.bool(forKey: "includeSubfolders") }
        set { defaults.set(newValue, forKey: "includeSubfolders") }
    }

    static var slideshowInterval: TimeInterval {
        get { defaults.object(forKey: "slideshowInterval") as? Double ?? 3 }
        set { defaults.set(newValue, forKey: "slideshowInterval") }
    }

    static var reopenLastFolder: Bool {
        get { defaults.object(forKey: "reopenLastFolder") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reopenLastFolder") }
    }
}

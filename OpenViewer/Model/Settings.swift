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

    static var gridStyle: GalleryLayout.Style {
        get { GalleryLayout.Style(rawValue: defaults.string(forKey: "gridStyle") ?? "") ?? .justified }
        set { defaults.set(newValue.rawValue, forKey: "gridStyle") }
    }

    /// Images whose longest side is below this many pixels are hidden (0 = show all).
    static var minimumImageSide: Int {
        get { defaults.integer(forKey: "minimumImageSide") }
        set { defaults.set(newValue, forKey: "minimumImageSide") }
    }

    static var transparencyBackground: TransparencyBackground {
        get { TransparencyBackground(rawValue: defaults.string(forKey: "transparencyBackground") ?? "") ?? .checkerboard }
        set {
            defaults.set(newValue.rawValue, forKey: "transparencyBackground")
            NotificationCenter.default.post(name: TransparencyBackground.didChange, object: nil)
        }
    }

    static var hideEmptyFolders: Bool {
        get { defaults.bool(forKey: "hideEmptyFolders") }
        set { defaults.set(newValue, forKey: "hideEmptyFolders") }
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

    /// The search box also matches text recognised inside images (indexed in the background).
    static var searchTextInImages: Bool {
        get { defaults.bool(forKey: "searchTextInImages") }
        set { defaults.set(newValue, forKey: "searchTextInImages") }
    }
}

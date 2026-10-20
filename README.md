<p align="center">
  <img src="OpenViewer/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" alt="OpenViewer icon">
</p>

<h1 align="center">OpenViewer</h1>

<p align="center">
  A fast, lightweight, open-source image viewer for iPad, built to browse <b>huge folders with subfolders</b>.
</p>

---

The Files app opens images one at a time, and Photos only shows your photo library. OpenViewer opens **any folder** that
the Files app can reach (iCloud Drive, On My iPad, USB/SSD drives, SMB servers and third-party providers) and shows
every image in it straight away. Nothing is imported or copied, and there are no accounts or ads.

Speed comes before features. See [`docs/MARKET_STUDY.md`](docs/MARKET_STUDY.md) for the market study (in Spanish)
behind the design.

## Features

- **Open any folder** with the system picker. Recent folders are remembered, and the last one reopens on launch.
- **Folder browsing** with cover thumbnails and item counts, or **Include Subfolders** to flatten the whole tree into one grid. The tree is scanned in the background and results stream in as they are found.
- **Dense grid** like Photos: pinch or press ⌘+ / ⌘− to change the thumbnail size, sort by natural name, date or size, and filter by name.
- **Full-screen viewer**: swipe between images, double-tap or pinch to zoom, zoom transition from the grid, and swipe down to close.
- **Scrubber** to jump anywhere in collections with thousands of images.
- **Slideshow** at 2, 3, 5 or 10 seconds (long-press the play button).
- **Animated GIF** playback, an **EXIF info** panel, Share, drag and drop to other apps, and multi-window / Stage Manager support.
- **Keyboard**: ← → / space to move, Home / End, Esc to close, I for info, S for slideshow, H to hide controls, ⌘O to open a folder, ⌘R to include subfolders, ⌘F to search.
- Formats: everything ImageIO decodes, including JPEG, PNG, HEIC/HEIF, WebP, AVIF, GIF, TIFF, BMP, PSD and RAW (DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2 and more).

## How it stays fast

| Technique | Effect |
|---|---|
| ImageIO `CGImageSourceCreateThumbnailAtIndex` downsampling | Images are decoded straight at cell or screen size, never at full resolution |
| Embedded EXIF/RAW previews used when large enough | RAW and camera JPEG thumbnails without a full decode |
| Memory cache + JPEG **disk cache** for thumbnails | Revisiting a folder is instant |
| Thumbnail sizes bucketed (256/512/768 px) | Changing the grid size reuses the cache |
| `OperationQueue` with priorities, request coalescing and cancellation | Fast scrolling never decodes off-screen cells |
| `UICollectionView` prefetching + compositional layout | Smooth with 100k+ items |
| Viewer shows the cached thumbnail first, then the screen-sized image, and preloads ±2 neighbours | Paging feels instant |
| High-resolution decode only when you zoom in | Memory stays low |

## Building

Requirements: Xcode 16 or later, iPadOS 18+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open OpenViewer.xcodeproj
```

Choose your team under *Signing & Capabilities*, then run on an iPad or an iPad simulator. Tests:

```bash
xcodebuild test -project OpenViewer.xcodeproj -scheme OpenViewer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

## Project layout

```
OpenViewer/
  App/        AppDelegate, SceneDelegate
  Model/      ImageItem / FolderItem, sorting, persisted settings
  Services/   FolderScanner, ImagePipeline (decode + caches), BookmarkStore, FolderInfoCache
  UI/         Home, Browser grid, Viewer, zoomable page, Info panel, cells
OpenViewerTests/
docs/MARKET_STUDY.md
```

## Roadmap

- On-demand download of iCloud files that are not stored locally
- Filmstrip and side-by-side compare
- Favourites and ratings stored separately (files are never modified)
- ZIP/CBZ support
- External display output

Contributions are welcome. Please keep the focus on speed and lightness.

## License

[MIT](LICENSE) © rldona

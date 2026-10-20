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
- **Folder browsing** with cover thumbnails and item counts, an option to hide folders that contain no images anywhere inside, or **Include Subfolders** to flatten the whole tree into one grid. The tree is scanned in the background and results stream in as they are found.
- **Justified grid** like Google Photos, where every image keeps its proportions, or a square grid. Pinch or press ⌘+ / ⌘− to resize, sort by natural name, date or size, and filter by name.
- **Full-screen viewer**: swipe between images, double-tap or pinch to zoom, zoom transition from the grid, and swipe down to close.
- **Favorites**: tap ♥︎ in the viewer, press F, or long-press a thumbnail. Filter any folder with *Favorites Only*, or open *Favorites* on the start screen to see favorites from all your folders. Folders can be favorited too (long-press a folder, or *Add Folder to Favorites* in the menu) and appear as shortcuts on the start screen. Favorites are stored inside the app and image files are never modified.
- **Select multiple images** like in Google Photos: long-press an image and, without lifting your finger, drag across or down to select a whole range (the grid scrolls by itself near the edges). You can also tap *Select* and then tap or swipe sideways. Share them, add or remove favorites, put them in a new folder, copy or move them anywhere the Files app can reach, or delete them (after a confirmation, they go to Recently Deleted in the Files app when the location supports it). ⌘A selects everything.
- **Compare two images**: select two and tap *Compare*. *Overlay* places B over A with an opacity slider, *Swipe* adds a draggable divider, and *Side by Side* keeps zoom and pan in sync. It is ideal for checking a scene's art against its collision map. Space flips between A and B, 1/2/3 switch modes and X swaps them.
- **Made for sprites and extracted assets**: choose a checkerboard, gray, black or white background for transparent images (*Transparency* in the menu, or B in the viewer), and hide tiny files with *Image Size* (for example, everything under 64 px).
- **Scrubber** to jump anywhere in collections with thousands of images.
- **Slideshow** at 2, 3, 5 or 10 seconds (long-press the play button).
- **Animated GIF** playback, an **EXIF info** panel, Share, and multi-window / Stage Manager support.
- **Keyboard**: ← → / space to move, Home / End, Esc to close, I for info, F to favorite, B to change the transparency background, S for slideshow, H to hide controls, ⌘O to open a folder, ⌘R to include subfolders, ⌘F to search.
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
- Filmstrip view
- Ratings and tags stored separately (files are never modified)
- ZIP/CBZ support
- External display output

Contributions are welcome. Please keep the focus on speed and lightness.

## License

[MIT](LICENSE) © rldona

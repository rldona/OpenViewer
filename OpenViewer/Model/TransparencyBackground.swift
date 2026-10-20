import UIKit

/// What shows through the transparent parts of PNG/WebP/GIF images (sprites, icons, cut-outs).
enum TransparencyBackground: String, CaseIterable {
    case checkerboard, gray, black, white

    static let didChange = Notification.Name("OpenViewer.transparencyBackgroundDidChange")

    var title: String {
        switch self {
        case .checkerboard: return "Checkerboard"
        case .gray: return "Gray"
        case .black: return "Black"
        case .white: return "White"
        }
    }

    var color: UIColor {
        switch self {
        case .checkerboard: return Self.checkerboardColor
        case .gray: return UIColor(white: 0.5, alpha: 1)
        case .black: return .black
        case .white: return .white
        }
    }

    var next: TransparencyBackground {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Classic editor checkerboard, softer in dark mode. Pattern images are drawn once per appearance.
    private static let checkerboardColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? darkPattern : lightPattern
    }
    private static let lightPattern = pattern(UIColor(white: 1, alpha: 1), UIColor(white: 0.85, alpha: 1))
    private static let darkPattern = pattern(UIColor(white: 0.24, alpha: 1), UIColor(white: 0.16, alpha: 1))

    private static func pattern(_ a: UIColor, _ b: UIColor) -> UIColor {
        let square: CGFloat = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: square * 2, height: square * 2), format: format).image { context in
            a.setFill()
            context.fill(CGRect(x: 0, y: 0, width: square * 2, height: square * 2))
            b.setFill()
            context.fill(CGRect(x: square, y: 0, width: square, height: square))
            context.fill(CGRect(x: 0, y: square, width: square, height: square))
        }
        return UIColor(patternImage: image)
    }
}

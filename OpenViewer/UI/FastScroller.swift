import UIKit

/// A draggable scroll handle on the trailing edge for very long grids. It fades in while
/// scrolling, and while dragged shows a bubble naming the folder (or position) under the finger.
final class FastScroller: UIView {
    /// Label for a content offset (e.g. the folder group there); nil falls back to a percentage.
    var labelProvider: ((CGFloat) -> String?)?

    private weak var scrollView: UIScrollView?
    private let track = UIView()
    private let thumb = UIView()
    private let bubble = GlassView(cornerRadius: 14)
    private let bubbleLabel = UILabel()
    private var hideWork: DispatchWorkItem?
    private var isDragging = false
    private var dragStartThumbY: CGFloat = 0

    private let thumbSize = CGSize(width: 10, height: 52)
    /// Only grids at least this many screens tall get a fast scroller.
    private let minimumScreens: CGFloat = 4

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The container stays opaque so it can be hit-tested; only its pieces fade.
        setVisible(false)

        track.backgroundColor = UIColor(white: 1, alpha: 0.10)
        track.layer.cornerRadius = 2
        addSubview(track)

        thumb.backgroundColor = Theme.accent
        thumb.layer.cornerRadius = thumbSize.width / 2
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.35
        thumb.layer.shadowRadius = 4
        thumb.layer.shadowOffset = .zero
        addSubview(thumb)

        bubbleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bubbleLabel.textColor = .label
        bubble.embed(bubbleLabel, insets: NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
        bubble.alpha = 0
        addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.trailingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: -10),
            bubble.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Fast scroll"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Touches outside the thumb's column pass through to the grid.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Still grabbable while faded out: the handle's spot on the edge is where people expect it.
        guard !isHidden, isUseful else { return false }
        return thumb.frame.insetBy(dx: -18, dy: -14).contains(point)
    }

    var isUseful: Bool {
        guard let scrollView else { return false }
        return scrollView.contentSize.height > scrollView.bounds.height * minimumScreens
    }

    private var trackRect: CGRect {
        CGRect(x: bounds.width - thumbSize.width - 6, y: 0, width: thumbSize.width, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.frame = CGRect(x: trackRect.midX - 2, y: 0, width: 4, height: bounds.height)
        if !isDragging { positionThumb() }
    }

    /// Called from the grid's scrollViewDidScroll.
    func scrollViewDidScroll() {
        // One indicator at a time: the system's thin bar only when this handle isn't offered.
        scrollView?.showsVerticalScrollIndicator = !isUseful
        guard isUseful else { setVisible(false); return }
        if !isDragging { positionThumb() }
        show()
        scheduleHide()
    }

    private func scrollFraction() -> CGFloat {
        guard let scrollView else { return 0 }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        guard maxY > minY else { return 0 }
        return min(max((scrollView.contentOffset.y - minY) / (maxY - minY), 0), 1)
    }

    private func positionThumb() {
        let travel = bounds.height - thumbSize.height
        thumb.frame = CGRect(x: trackRect.minX, y: travel * scrollFraction(),
                             width: thumbSize.width, height: thumbSize.height)
    }

    private var isShown = false

    private func setVisible(_ visible: Bool) {
        isShown = visible
        track.alpha = visible ? 1 : 0
        thumb.alpha = visible ? 1 : 0
    }

    private func show() {
        hideWork?.cancel()
        guard !isShown else { return }
        UIView.animate(withDuration: 0.2) { self.setVisible(true) }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            UIView.animate(withDuration: 0.4) { self.setVisible(false) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let scrollView else { return }
        switch pan.state {
        case .began:
            isDragging = true
            dragStartThumbY = thumb.frame.minY
            show()
            UIView.animate(withDuration: 0.15) {
                self.bubble.alpha = 1
                self.thumb.transform = CGAffineTransform(scaleX: 1.3, y: 1)
            }
            fallthrough
        case .changed:
            let travel = max(bounds.height - thumbSize.height, 1)
            let y = min(max(dragStartThumbY + pan.translation(in: self).y, 0), travel)
            thumb.frame.origin.y = y
            let fraction = y / travel
            let minY = -scrollView.adjustedContentInset.top
            let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            let offset = minY + (maxY - minY) * fraction
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
            let probe = offset + scrollView.adjustedContentInset.top + 8
            bubbleLabel.text = labelProvider?(probe) ?? "\(Int((fraction * 100).rounded()))%"
        default:
            isDragging = false
            UIView.animate(withDuration: 0.2) {
                self.bubble.alpha = 0
                self.thumb.transform = .identity
            }
            scheduleHide()
        }
    }

    override func accessibilityIncrement() { step(by: -0.1) }
    override func accessibilityDecrement() { step(by: 0.1) }

    private func step(by delta: CGFloat) {
        guard let scrollView else { return }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        let fraction = min(max(scrollFraction() + delta, 0), 1)
        scrollView.setContentOffset(CGPoint(x: 0, y: minY + (maxY - minY) * fraction), animated: true)
    }
}

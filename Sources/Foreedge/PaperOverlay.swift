import AppKit
import QuartzCore

/// PDFKit owns page positioning. This view never consumes a click or replaces PDF text.
final class PaperOverlay: NSView {
    private let grainLayer = CALayer()
    private var currentImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.compositingFilter = "multiplyBlendMode"
        grainLayer.compositingFilter = "multiplyBlendMode"
        grainLayer.contentsGravity = .resize
        grainLayer.minificationFilter = .linear
        grainLayer.magnificationFilter = .linear
        layer?.addSublayer(grainLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grainLayer.frame = bounds
        CATransaction.commit()
    }

    func update(appearance: PaperAppearance, texture: PaperTexture?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Plain mode removes the composited overlay entirely from the visible result.
        isHidden = appearance.mode == .plain
        layer?.backgroundColor = appearance.surfaceColor(texture: texture)
        let image = texture?.field(for: appearance.experiment).image
        if currentImage !== image {
            grainLayer.contents = image
            currentImage = image
        }
        grainLayer.opacity = appearance.textureOpacity
        CATransaction.commit()
    }
}

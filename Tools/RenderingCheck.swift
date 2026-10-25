import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import QuartzCore
import UniformTypeIdentifiers

@main
enum RenderingCheck {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/rendering-check", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let document = try BaselineDocument.make()
        let pageData = document.dataRepresentation()!
        let texture = try PaperTexture.generate(pageData: pageData)
        let repeatTexture = try PaperTexture.generate(pageData: pageData)
        for experiment in PaperExperiment.allCases {
            check(texture.field(for: experiment).image.dataProvider!.data! as Data == repeatTexture.field(for: experiment).image.dataProvider!.data! as Data,
                         "Identical inputs must produce identical surfaces")
        }
        check(texture.byteCount == 4 * 1224 * 1584, "Four full-page grayscale maps must remain bounded")
        do {
            _ = try PaperTexture.generate(pageData: Data("invalid".utf8))
            preconditionFailure("Invalid PDFs must fail preparation")
        } catch PaperTexture.GenerationError.invalidPDF {}

        let mask = try PaperTexture.pageLuminance(pageData)
        let maskImage = CGImage(width: PaperTexture.width, height: PaperTexture.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: PaperTexture.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                               provider: CGDataProvider(data: Data(mask) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        try write(maskImage, to: output.appendingPathComponent("luminance-mask.png"))
        let page = document.page(at: 0)!
        let originalText = document.string
        let width = PaperTexture.width
        let height = PaperTexture.height
        let modes: [PaperMode] = [.plain, .warm, .paper]
        let plain = render(page: page, appearance: PaperAppearance(mode: .plain), texture: texture)
        let plainBytes = bytes(plain)
        try write(plain, to: output.appendingPathComponent("plain.png"))
        try write(render(page: page, appearance: PaperAppearance(mode: .warm), texture: texture), to: output.appendingPathComponent("warm.png"))
        for experiment in PaperExperiment.allCases {
            let appearance = PaperAppearance(experiment: experiment)
            let image = render(page: page, appearance: appearance, texture: texture)
            try write(image, to: output.appendingPathComponent(experiment.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"))
            let renderedBytes = bytes(image)
            for index in stride(from: 0, to: renderedBytes.count, by: 4) where plainBytes[index] < 40 {
                check(renderedBytes[index] <= plainBytes[index] + 1, "Treatment must not lighten black ink")
            }
        }

        // Compare on a completely white page, isolating paper brightness from document content.
        let smoothMean = statistics(bytes(render(page: nil, appearance: PaperAppearance(mode: .warm), texture: texture))).mean
        var maximumMeanDrift = 0.0
        for experiment in [PaperExperiment.balanced, .relief, .adaptive] {
            for amount in [0.0, 0.45, 1.0] {
                let appearance = PaperAppearance(experiment: experiment, grain: amount)
                let stats = statistics(bytes(render(page: nil, appearance: appearance, texture: texture)))
                let drift = abs(stats.mean - smoothMean)
                maximumMeanDrift = max(maximumMeanDrift, drift)
                check(drift < 1.0, "Grain must hold mean paper brightness within one 8-bit level: \(drift)")
                if amount > 0 { check(stats.variance > 0.1, "Surface must retain visible variation") }
            }
        }
        let reliefBytes = texture.field(for: .relief).image.dataProvider!.data! as Data
        let adaptiveBytes = texture.field(for: .adaptive).image.dataProvider!.data! as Data
        let reliefMean = texture.field(for: .relief).mean * 255
        let adaptiveMean = texture.field(for: .adaptive).mean * 255
        var darkReliefEnergy = 0.0, darkAdaptiveEnergy = 0.0
        var lightReliefEnergy = 0.0, lightAdaptiveEnergy = 0.0
        for index in 0..<(width * height) {
            let r = pow(Double(reliefBytes[index]) - reliefMean, 2)
            let a = pow(Double(adaptiveBytes[index]) - adaptiveMean, 2)
            if plainBytes[index * 4] < 65 {
                darkReliefEnergy += r
                darkAdaptiveEnergy += a
            } else if plainBytes[index * 4] > 245 {
                lightReliefEnergy += r
                lightAdaptiveEnergy += a
            }
        }
        let darkEnergyRatio = darkAdaptiveEnergy / darkReliefEnergy
        let lightEnergyRatio = lightAdaptiveEnergy / lightReliefEnergy
        check(darkEnergyRatio < 0.10, "Adaptive grain should strongly attenuate dark content: ratio \(darkEnergyRatio), bright ratio \(lightEnergyRatio)")
        check(abs(lightEnergyRatio - 1) < 0.03, "Adaptive grain must retain the bright-paper texture")
        check(document.string == originalText && originalText?.contains("A quiet page") == true,
                     "Appearance must leave PDF text intact")

        // AppKit layer contracts: pass clicks through, retain the same image, disable animations,
        // and hide the entire treatment in Plain mode. No screenshot permission required.
        _ = NSApplication.shared
        let pdfView = PDFView()
        let coordinator = PDFSurface.Coordinator(appearance: PaperAppearance(), texture: texture)
        let overlay = coordinator.pdfView(pdfView, overlayViewFor: page) as! PaperOverlay
        check(overlay.hitTest(CGPoint(x: 100, y: 100)) == nil)
        check(overlay.layer?.compositingFilter as? String == "multiplyBlendMode")
        let grain = overlay.layer!.sublayers!.first!
        let retainedImage = grain.contents as! CGImage
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<1000 {
            coordinator.update(appearance: PaperAppearance(mode: modes[index % 3], warmth: Double(index % 100) / 100), texture: texture)
        }
        let updateMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        coordinator.update(appearance: PaperAppearance(mode: .plain), texture: texture)
        check(overlay.isHidden)
        coordinator.update(appearance: PaperAppearance(mode: .paper), texture: texture)
        check(!overlay.isHidden && grain.contents as! CGImage === retainedImage)
        check(grain.animationKeys()?.isEmpty ?? true)
        check(overlay.layer?.animationKeys()?.isEmpty ?? true)
        for experiment in PaperExperiment.allCases {
            coordinator.update(appearance: PaperAppearance(experiment: experiment), texture: texture)
            let cached = texture.field(for: experiment).image
            check(grain.contents as! CGImage === cached, "Experiment switch must reuse its prepared image")
            coordinator.update(appearance: PaperAppearance(experiment: experiment, grain: 0.9), texture: texture)
            check(grain.contents as! CGImage === cached, "Changing grain must keep the selected image")
        }
        CATransaction.flush()

        // Exercise the actual PDFKit overlay-provider lifecycle in a temporary window.
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 820, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Foreedge rendering verification"
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.pageOverlayViewProvider = coordinator
        pdfView.document = document
        pdfView.autoScales = true
        window.contentView = pdfView
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        func installedOverlays(in view: NSView) -> [PaperOverlay] {
            (view as? PaperOverlay).map { [$0] } ?? view.subviews.flatMap { installedOverlays(in: $0) }
        }
        let installed = installedOverlays(in: pdfView)
        check(installed.count == 1, "PDFKit must install exactly one page overlay")
        let liveOverlay = installed[0]
        check(liveOverlay.bounds.width > 0 && liveOverlay.bounds.height > 0)
        let viewBeforeResize = liveOverlay
        window.setContentSize(NSSize(width: 720, height: 760))
        pdfView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let resized = installedOverlays(in: pdfView)
        check(resized.count == 1 && resized[0] === viewBeforeResize, "Resizing must retain the overlay")
        check(liveOverlay.layer!.sublayers!.first!.frame == liveOverlay.bounds,
                     "Texture must track page bounds after resizing")
        let selection = page.selection(for: NSRange(location: 0, length: 8))
        pdfView.setCurrentSelection(selection, animate: false)
        check(pdfView.currentSelection?.string?.isEmpty == false, "Native PDF selection must remain available")
        check(pdfView.document === document, "Appearance changes must not replace the document")
        window.orderOut(nil)
        window.close()

        // Sample repeated warm generations; these are CPU setup timings only.
        var times = [texture.generationMilliseconds, repeatTexture.generationMilliseconds]
        for _ in 0..<3 { times.append(try PaperTexture.generate(pageData: pageData).generationMilliseconds) }
        times.sort()
        let report = """
        Rendering checks passed.
        Four surfaces: \(width) × \(height), \(texture.byteCount) total bytes of grayscale backing.
        Surface-set preparation, 5 samples (ms): \(times.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        Median CPU preparation: \(String(format: "%.2f", times[2])) ms.
        1,000 CPU layer-property updates: \(String(format: "%.2f", updateMilliseconds)) ms (excludes compositor/GPU/presentation).
        Maximum white-page encoded red-channel mean drift: \(String(format: "%.3f", maximumMeanDrift)) / 255 across experimental grain settings.
        Adaptive texture energy relative to relief: \(String(format: "%.4f", darkEnergyRatio)) over dark content, \(String(format: "%.4f", lightEnergyRatio)) over bright content.
        Deterministic surfaces, bounded cache, invalid-input handling, dark-ink preservation, text preservation, pass-through hit testing,
        cached image identity, Plain-mode hiding, and absence of explicit layer animations verified.
        PDFKit overlay installation, retention across resizing, page bounds, and native selection verified.
        Reference PNGs are offscreen Core Graphics renders, not live-window screenshots.
        These measurements do not establish first-frame latency, idle energy, total memory, or GPU cost.
        """
        print(report)
        try report.write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }

    /// Reference for the multiply layer stack, not a WindowServer screenshot.
    private static func render(page: PDFPage?, appearance: PaperAppearance, texture: PaperTexture) -> CGImage {
        let width = PaperTexture.width, height = PaperTexture.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        page?.draw(with: .mediaBox, to: context)
        if appearance.mode != .plain {
            context.setBlendMode(.multiply)
            context.setFillColor(appearance.surfaceColor(texture: texture))
            let rect = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
            context.fill(rect)
            context.setAlpha(CGFloat(appearance.textureOpacity))
            context.draw(texture.field(for: appearance.experiment).image, in: rect)
        }
        return context.makeImage()!
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        Array(image.dataProvider!.data! as Data)
    }

    private static func statistics(_ bytes: [UInt8]) -> (mean: Double, variance: Double) {
        var sum = 0.0, squareSum = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let value = Double(bytes[index])
            sum += value
            squareSum += value * value
        }
        let count = Double(bytes.count / 4)
        let mean = sum / count
        return (mean, squareSum / count - mean * mean)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// Keep validation failures readable in optimized benchmark builds.
private func check(_ condition: @autoclosure () -> Bool, _ message: String = "Rendering check failed") {
    if !condition() {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

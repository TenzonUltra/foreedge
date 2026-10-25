import CoreGraphics
import Foundation

struct PaperField {
    let image: CGImage
    /// Mean encoded grayscale transmission, used to compensate the multiply layer.
    let mean: Double
    var byteCount: Int { image.bytesPerRow * image.height }
}

/// A bounded set of deterministic, full-page material experiments; prepared once.
struct PaperTexture {
    static let width = 1224
    static let height = 1584
    private let fields: [PaperExperiment: PaperField]
    let generationMilliseconds: Double

    // The original image also identifies this immutable set for view-update comparisons.
    var image: CGImage { fields[.original]!.image }
    var byteCount: Int { fields.values.reduce(0) { $0 + $1.byteCount } }
    func field(for experiment: PaperExperiment) -> PaperField { fields[experiment] ?? fields[.relief]! }

    enum GenerationError: Error { case imageCreationFailed, invalidPDF }

    /// Shared paper fields never inspect the PDF. A process-wide worker caches this result.
    static func generateBase() throws -> PaperTexture {
        let start = ProcessInfo.processInfo.systemUptime
        let count = width * height
        var original = [UInt8](repeating: 255, count: count)
        var heightField = [Float](repeating: 0, count: count)
        var balancedValues = [Float](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let formation = noise(Double(x) / 83, Double(y) / 91, seed: 11)
                let clumps = noise(Double(x) / 9, Double(y) / 11, seed: 37)
                let fibers = noise(Double(x) / 1.4, Double(y) / 5.5, seed: 73)
                let tooth = sample(x, y, seed: 101)
                let density = 0.22 * formation + 0.23 * clumps + 0.35 * fibers + 0.20 * tooth
                let index = y * width + x
                original[index] = UInt8((255 - 42 * density).rounded())
                balancedValues[index] = Float((0.5 - density) * 30)
                // Coherent relief from the same fibers, without turning pixel noise into bumps.
                heightField[index] = Float(0.65 * fibers + 0.25 * clumps + 0.10 * formation)
            }
        }

        var reliefValues = balancedValues
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let dx = heightField[y * width + min(width - 1, x + 1)] - heightField[y * width + max(0, x - 1)]
                let dy = heightField[min(height - 1, y + 1) * width + x] - heightField[max(0, y - 1) * width + x]
                // Shallow directional shading approximation, not a physical scattering simulation.
                reliefValues[index] += (-dx - dy) * 14
            }
        }
        let fields: [PaperExperiment: PaperField] = [
            .original: try makeField(original),
            .balanced: try makeField(centered(balancedValues)),
            .relief: try makeField(centered(reliefValues))
        ]
        return PaperTexture(fields: fields,
                            generationMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    // Retained for the reproducible, single-page rendering check.
    static func generate(pageData: Data) throws -> PaperTexture {
        let start = ProcessInfo.processInfo.systemUptime
        let base = try generateBase()
        let result = try base.adapting(luminance: pageLuminance(pageData))
        return PaperTexture(fields: result.fields,
                            generationMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    func adapting(to document: CGPDFDocument, pageIndex: Int) throws -> PaperTexture {
        try adapting(luminance: Self.pageLuminance(document, pageIndex: pageIndex))
    }

    private func adapting(luminance: [UInt8]) throws -> PaperTexture {
        let relief = field(for: .relief)
        let pixels = relief.image.dataProvider!.data! as Data
        var values = [Float](repeating: 0, count: Self.width * Self.height)
        let mean = Float(relief.mean * 255)
        for index in values.indices {
            let light = Float(luminance[index]) / 255
            let t = min(1, max(0, (light - 0.20) / 0.70))
            let strength = t * t * (3 - 2 * t)
            values[index] = (Float(pixels[index]) - mean) * strength
        }
        var prepared = fields
        prepared[.adaptive] = try Self.makeField(Self.centered(values))
        return PaperTexture(fields: prepared, generationMilliseconds: generationMilliseconds)
    }

    /// Keep all experimental maps near the same mean, with room on both sides for detail.
    private static func centered(_ values: [Float]) -> [UInt8] {
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        return values.map { UInt8(min(255, max(0, (242 + Double($0) - mean).rounded()))) }
    }

    private static func makeField(_ pixels: [UInt8]) throws -> PaperField {
        let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw GenerationError.imageCreationFailed
        }
        return PaperField(image: image, mean: mean)
    }

    /// This worker owns a separate Core Graphics PDF. PDFKit objects stay on the main actor.
    /// Only the mask is rasterized; visible text continues to come from the native PDF view.
    static func pageLuminance(_ data: Data) throws -> [UInt8] {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { throw GenerationError.invalidPDF }
        return try pageLuminance(pdf, pageIndex: 0)
    }

    private static func pageLuminance(_ pdf: CGPDFDocument, pageIndex: Int) throws -> [UInt8] {
        guard pageIndex >= 0, let page = pdf.page(at: pageIndex + 1),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            throw GenerationError.invalidPDF
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        // Fit explicitly: getDrawingTransform(... preserveAspectRatio: false) on
        // this SDK centers a smaller page without scaling it up to our sample grid.
        let rotation = CGAffineTransform(rotationAngle: -CGFloat(page.rotationAngle) * .pi / 180)
        let bounds = page.getBoxRect(.mediaBox).applying(rotation)
        guard bounds.width > 0, bounds.height > 0 else { throw GenerationError.invalidPDF }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(rotation)
        context.drawPDFPage(page)
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var luminance = [UInt8](repeating: 255, count: width * height)
        for row in 0..<height {
            let start = source.advanced(by: row * context.bytesPerRow)
            luminance.replaceSubrange((row * width)..<((row + 1) * width), with: UnsafeBufferPointer(start: start, count: width))
        }
        return luminance
    }

    private static func sample(_ x: Int, _ y: Int, seed: UInt32) -> Double {
        var value = UInt32(truncatingIfNeeded: x) &* 0x1f123bb5
        value ^= UInt32(truncatingIfNeeded: y) &* 0x5f356495
        value ^= seed &* 0x9e3779b9
        value ^= value >> 16
        value = value &* 0x7feb352d
        value ^= value >> 15
        value = value &* 0x846ca68b
        value ^= value >> 16
        return Double(value & 0x00ffffff) / Double(0x00ffffff)
    }

    private static func noise(_ x: Double, _ y: Double, seed: UInt32) -> Double {
        let ix = Int(x), iy = Int(y)
        let fx = x - Double(ix), fy = y - Double(iy)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = sample(ix, iy, seed: seed) * (1 - sx) + sample(ix + 1, iy, seed: seed) * sx
        let bottom = sample(ix, iy + 1, seed: seed) * (1 - sx) + sample(ix + 1, iy + 1, seed: seed) * sx
        return top * (1 - sy) + bottom * sy
    }
}

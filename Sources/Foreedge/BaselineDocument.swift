import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Original vector/text fixture generated once at launch, with no disk or network input.
/// Fixture creation is setup work, not a measurement of PDF rendering speed.
enum BaselineDocument {
    enum CreationError: LocalizedError {
        case failed

        var errorDescription: String? { "The baseline PDF could not be generated." }
    }

    static func make() throws -> PDFDocument {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CreationError.failed
        }

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(page)

        func line(_ text: String, at y: CGFloat, size: CGFloat, font: String = "Georgia", gray: CGFloat = 0.08) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            context.textPosition = CGPoint(x: 64, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }

        line("F O R E E D G E   /   R E N D E R I N G   S T U D Y   0 1", at: 724, size: 9, font: "Helvetica", gray: 0.4)
        line("A quiet page", at: 669, size: 32)
        line("The same page. A different surface.", at: 640, size: 11, font: "Helvetica", gray: 0.4)

        let paragraphs = [
            [
                "Morning light settled across the desk. Beside the window,",
                "an open book waited where it had been left the night before.",
                "There was no hurry to turn the page. A sentence could be read",
                "once for its meaning, then again for the sound of its words."
            ],
            [
                "The page should feel still. Letters should keep their edges,",
                "small details should remain clear, and the space around the",
                "text should make reading easy. Every later experiment begins",
                "with this same page, at the same size, on the same display."
            ]
        ]
        var y: CGFloat = 589
        for paragraph in paragraphs {
            for text in paragraph {
                line(text, at: y, size: 13)
                y -= 22
            }
            y -= 16
        }

        line("SMALL TYPE", at: 345, size: 9, font: "Helvetica", gray: 0.4)
        line("10 pt — Fine strokes, punctuation, and figures: 0123456789.", at: 322, size: 10)
        line("12 pt — Fine strokes, punctuation, and figures: 0123456789.", at: 297, size: 12)
        line("16 pt — Reading should feel effortless.", at: 268, size: 16)

        line("NEUTRAL TONES / VECTOR DETAIL", at: 216, size: 9, font: "Helvetica", gray: 0.4)
        for index in 0..<8 {
            context.setFillColor(CGColor(gray: CGFloat(index) / 7, alpha: 1))
            context.fill(CGRect(x: 64 + CGFloat(index) * 60, y: 172, width: 56, height: 24))
        }
        for (index, width) in [0.25, 0.5, 1.0].enumerated() {
            context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
            context.setLineWidth(width)
            let lineY = 144 - CGFloat(index) * 12
            context.move(to: CGPoint(x: 64, y: lineY))
            context.addLine(to: CGPoint(x: 544, y: lineY))
            context.strokePath()
        }
        line("01", at: 64, size: 10, font: "Helvetica", gray: 0.4)

        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else {
            throw CreationError.failed
        }
        return document
    }
}

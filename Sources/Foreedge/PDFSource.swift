import Foundation

enum PDFSource: Sendable {
    case data(Data)
    case file(URL)
}

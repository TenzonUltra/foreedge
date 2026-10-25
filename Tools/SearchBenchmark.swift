import Foundation
import PDFKit
/// Read-only academic-term benchmark. Use a fresh cache path for a cold-index measurement.
@main enum SearchBenchmark {
 static func main() async throws {
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let cache = URL(fileURLWithPath: CommandLine.arguments[2])
  let index = SearchIndex(url: cache)
  let start = ProcessInfo.processInfo.systemUptime
  let key = try await index.prepare(SearchDocument(source: .file(source), title: source.lastPathComponent))
  var firstHit: Double?
  while true {
   let r = try await index.search("vector space", documents: [key])
   if firstHit == nil && !r.hits.isEmpty { firstHit = (ProcessInfo.processInfo.systemUptime-start)*1000 }
   if r.isComplete { break }
   try await Task.sleep(nanoseconds: 500_000_000)
  }
  print("INDEX: \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms; first result \(Int(firstHit ?? -1)) ms; extracted \(await index.extractedPages) pages")
  for query in ["vector space", "vector space", "rare space", "representation", "qzxnonexistent"] {
   let start = ProcessInfo.processInfo.systemUptime
   let r = try await index.search(query, documents: [key])
   print("INDEXED \(query): \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms; \(r.hits.count) distinct pages; broader \(r.broader); first pages \(r.hits.prefix(10).map { $0.page+1 }); matching words \(r.hits.prefix(4).map(\.matchedWords))")
   for hit in r.hits.prefix(3) {
    guard let doc = PDFDocument(url: source), let selected = doc.page(at: hit.page)?.selection(for: NSRange(location: hit.offset, length: hit.length))?.string else { fatalError("Invalid result range") }
    print("  native selection valid: \(selected.prefix(45))")
   }
  }
  let restarted = SearchIndex(url: cache)
  let second = try await restarted.prepare(SearchDocument(source: .file(source), title: source.lastPathComponent))
  let r = try await restarted.search("vector space", documents: [second])
  print("RESTART: complete \(r.isComplete), \(r.hits.count) pages; re-extracted \(await restarted.extractedPages)")
 }
}

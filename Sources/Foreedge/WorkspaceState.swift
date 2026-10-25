import Foundation

enum PaneDirection: CaseIterable { case left, right, up, down }

enum SplitAxis: String, Codable { case horizontal, vertical }

indirect enum PaneLayout: Codable, Equatable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    static let gap: CGFloat = 2
    static func firstLength(total: CGFloat, axis: SplitAxis, ratio: Double) -> CGFloat {
        let available = max(0, total - gap)
        let minimum = min(axis == .horizontal ? 260.0 : 200.0, available / 2)
        let fraction = ratio.isFinite ? min(0.8, max(0.2, ratio)) : 0.5
        return min(available - minimum, max(minimum, available * fraction))
    }
    /// Top-left coordinates, using exactly the same divider/minimum sizes as the UI.
    func frames(in bounds: CGRect) -> [(id: UUID, rect: CGRect)] {
        switch self {
        case .pane(let id): return [(id, bounds)]
        case .split(_, let axis, let ratio, let a, let b):
            var first = bounds, second = bounds
            let length = Self.firstLength(total: axis == .horizontal ? bounds.width : bounds.height, axis: axis, ratio: ratio)
            if axis == .horizontal {
                first.size.width = length; second.origin.x += length + Self.gap
                second.size.width = max(0, bounds.width - length - Self.gap)
            } else {
                first.size.height = length; second.origin.y += length + Self.gap
                second.size.height = max(0, bounds.height - length - Self.gap)
            }
            return a.frames(in: first) + b.frames(in: second)
        }
    }
    func neighbor(of id: UUID, toward direction: PaneDirection, in bounds: CGRect) -> UUID? {
        let frames = frames(in: bounds)
        guard let current = frames.first(where: { $0.id == id })?.rect else { return nil }
        let horizontal = direction == .left || direction == .right
        let center = horizontal ? current.midY : current.midX
        let candidates = frames.enumerated().compactMap { index, item -> (UUID, CGFloat, CGFloat, CGFloat, Int)? in
            guard item.id != id else { return nil }
            let rect = item.rect
            let distance: CGFloat
            switch direction {
            case .left: distance = current.minX - rect.maxX
            case .right: distance = rect.minX - current.maxX
            case .up: distance = current.minY - rect.maxY
            case .down: distance = rect.minY - current.maxY
            }
            let low = horizontal ? rect.minY : rect.minX, high = horizontal ? rect.maxY : rect.maxX
            let overlap = min(high, horizontal ? current.maxY : current.maxX) - max(low, horizontal ? current.minY : current.minX)
            guard distance >= -0.001, overlap > 0.001 else { return nil }
            // Prefer the adjacent edge, then the pane aligned with the current center.
            return (item.id, distance, max(0, max(low - center, center - high)), abs((low + high) / 2 - center), index)
        }
        return candidates.min {
            if abs($0.1 - $1.1) > 0.001 { return $0.1 < $1.1 }
            if abs($0.2 - $1.2) > 0.001 { return $0.2 < $1.2 }
            if abs($0.3 - $1.3) > 0.001 { return $0.3 < $1.3 }
            return $0.4 < $1.4
        }?.0
    }

    var paneIDs: [UUID] {
        switch self { case .pane(let id): return [id]; case .split(_, _, _, let a, let b): return a.paneIDs + b.paneIDs }
    }
    func replacing(_ pane: UUID, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let id): return id == pane ? replacement : self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio, first: a.replacing(pane, with: replacement), second: b.replacing(pane, with: replacement))
        }
    }
    func removing(_ pane: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id): return id == pane ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            let left = a.removing(pane), right = b.removing(pane)
            if let left, let right { return .split(id: id, axis: axis, ratio: ratio, first: left, second: right) }
            return left ?? right
        }
    }
    func settingRatio(_ split: UUID, to value: Double) -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: id == split ? min(0.8, max(0.2, value)) : ratio,
                          first: a.settingRatio(split, to: value), second: b.settingRatio(split, to: value))
        }
    }
}

struct ReadingTabState: Codable, Identifiable {
    var id = UUID()
    var bookID: UUID?
    var location: BookLocation?
    var back: [BookLocation] = []
    var forward: [BookLocation] = []
}
struct ReadingPaneState: Codable, Identifiable {
    var id = UUID()
    var tabs: [ReadingTabState] = [ReadingTabState()]
    var activeTabID: UUID?
}
struct StudyWorkspace: Codable, Identifiable {
    var id = UUID()
    var name: String
    var scope = "all"
    var layout: PaneLayout
    var panes: [ReadingPaneState]
    var activePaneID: UUID

    init(name: String, pane: ReadingPaneState = ReadingPaneState(), scope: String = "all") {
        self.name = name; self.scope = scope; self.panes = [pane]
        self.layout = .pane(pane.id); self.activePaneID = pane.id
    }
}

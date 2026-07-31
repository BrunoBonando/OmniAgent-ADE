import Foundation

struct PaneDescriptor: Equatable {
    let id: String
    let sessionID: String
    var label: String?
    var group: String?
    var groupLabel: String?
}

struct PaneGridShape: Equatable {
    let columns: Int
    let rows: Int
}

enum PaneDirection {
    case left
    case right
    case up
    case down
}

enum PaneLayoutError: Error, Equatable {
    case duplicatePane
    case maximumPanes
}

struct PaneLayout {
    static let maximumPanes = 8

    private(set) var panes: [String: PaneDescriptor]
    private(set) var cells: [String?]
    private(set) var focusedPaneID: String?

    var paneIDs: [String] {
        cells.compactMap { $0 }
    }

    var shape: PaneGridShape {
        Self.shape(for: panes.count)
    }

    init(panes descriptors: [PaneDescriptor]) throws {
        guard descriptors.count <= Self.maximumPanes else {
            throw PaneLayoutError.maximumPanes
        }
        var panes: [String: PaneDescriptor] = [:]
        for descriptor in descriptors {
            guard panes.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw PaneLayoutError.duplicatePane
            }
        }
        self.panes = panes
        cells = Self.cells(for: descriptors.map(\.id))
        focusedPaneID = descriptors.first?.id
    }

    mutating func add(_ pane: PaneDescriptor) throws {
        guard panes[pane.id] == nil else { throw PaneLayoutError.duplicatePane }
        guard panes.count < Self.maximumPanes else { throw PaneLayoutError.maximumPanes }
        let current = paneIDs
        panes[pane.id] = pane
        if current.count == 2 {
            cells = [current[0], pane.id, current[1], nil]
        } else {
            cells = Self.cells(for: current + [pane.id])
        }
        focusedPaneID = pane.id
    }

    @discardableResult
    mutating func remove(_ id: String) -> PaneDescriptor? {
        guard let removed = panes.removeValue(forKey: id) else { return nil }
        let current = paneIDs
        let removedIndex = current.firstIndex(of: id) ?? 0
        let remaining = current.filter { $0 != id }
        cells = Self.cells(for: remaining)
        if focusedPaneID == id {
            focusedPaneID = remaining.indices.contains(removedIndex - 1)
                ? remaining[removedIndex - 1]
                : remaining.indices.contains(removedIndex) ? remaining[removedIndex] : remaining.first
        }
        return removed
    }

    @discardableResult
    mutating func swap(_ first: String, _ second: String) -> Bool {
        guard
            first != second,
            let firstIndex = cells.firstIndex(where: { $0 == first }),
            let secondIndex = cells.firstIndex(where: { $0 == second })
        else { return false }
        cells.swapAt(firstIndex, secondIndex)
        return true
    }

    @discardableResult
    mutating func focus(_ id: String) -> Bool {
        guard panes[id] != nil else { return false }
        focusedPaneID = id
        return true
    }

    @discardableResult
    mutating func focus(_ direction: PaneDirection) -> String? {
        guard let id = neighbor(in: direction) else { return nil }
        focusedPaneID = id
        return id
    }

    func neighbor(in direction: PaneDirection) -> String? {
        guard
            let focusedPaneID,
            let index = cells.firstIndex(where: { $0 == focusedPaneID })
        else { return nil }
        let column = index / shape.rows
        let row = index % shape.rows
        let target: Int
        switch direction {
        case .left where column > 0: target = index - shape.rows
        case .right where column + 1 < shape.columns: target = index + shape.rows
        case .up where row > 0: target = index - 1
        case .down where row + 1 < shape.rows: target = index + 1
        default: return nil
        }
        return cells[target]
    }

    mutating func updateMetadata(
        id: String,
        label: String?,
        group: String?,
        groupLabel: String?
    ) {
        guard var pane = panes[id] else { return }
        pane.label = label
        pane.group = group
        pane.groupLabel = groupLabel
        panes[id] = pane
    }

    private static func shape(for count: Int) -> PaneGridShape {
        switch count {
        case 0...1: return PaneGridShape(columns: 1, rows: 1)
        case 2: return PaneGridShape(columns: 2, rows: 1)
        case 3...4: return PaneGridShape(columns: 2, rows: 2)
        case 5...6: return PaneGridShape(columns: 3, rows: 2)
        default: return PaneGridShape(columns: 4, rows: 2)
        }
    }

    private static func cells(for ids: [String]) -> [String?] {
        guard !ids.isEmpty else { return [] }
        let shape = shape(for: ids.count)
        return ids.map(Optional.some)
            + Array(repeating: nil, count: shape.columns * shape.rows - ids.count)
    }
}

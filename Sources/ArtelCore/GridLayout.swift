import Foundation

public struct GridSpan: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int = 1, rows: Int = 1) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct GridPlacement: Equatable, Sendable {
    public var index: Int
    public var row: Int
    public var column: Int
    public var span: GridSpan

    public init(index: Int, row: Int, column: Int, span: GridSpan) {
        self.index = index
        self.row = row
        self.column = column
        self.span = span
    }
}

/// Grid geometry for session cards: fill the space while few sessions, scroll vertically when many.
public struct GridLayout: Equatable, Sendable {
    public var rows: Int
    public var columns: Int
    public var cardWidth: Double
    public var cardHeight: Double
    public var placements: [GridPlacement]

    public static let minCardWidth = 460.0
    public static let minCardHeight = 260.0
    public static let spacing = 8.0
    /// Rows that share the visible height; more rows scroll.
    public static let visibleRows = 2

    public static func compute(count: Int, width: Double, height: Double) -> GridLayout {
        compute(spans: Array(repeating: GridSpan(), count: count), width: width, height: height)
    }

    public static func compute(spans: [GridSpan], width: Double, height: Double) -> GridLayout {
        guard !spans.isEmpty else {
            return GridLayout(rows: 0, columns: 0, cardWidth: 0, cardHeight: 0, placements: [])
        }
        let maxColumns = max(1, Int((width + spacing) / (minCardWidth + spacing)))
        // One row while the cards fit side by side (at most 3); otherwise 2×2, 3×2…, then more rows below.
        let columns = spans.count <= 3 && spans.count <= maxColumns
            ? spans.count
            : min(maxColumns, Int((Double(spans.count) / Double(visibleRows)).rounded(.up)))
        let cardWidth = (width - spacing * Double(columns - 1)) / Double(columns)
        let baseRows = Int((Double(spans.count) / Double(columns)).rounded(.up))
        let shown = Double(min(baseRows, visibleRows))
        let cardHeight = max(minCardHeight, (height - spacing * (shown - 1)) / shown)

        var occupied = Set<Cell>()
        var placements: [GridPlacement] = []
        var row = 0
        var column = 0
        for (index, requested) in spans.enumerated() {
            let span = GridSpan(columns: min(columns, requested.columns), rows: requested.rows)
            while true {
                if column + span.columns > columns {
                    row += 1
                    column = 0
                }
                let cells = Self.cells(row: row, column: column, span: span)
                if occupied.isDisjoint(with: cells) {
                    occupied.formUnion(cells)
                    placements.append(GridPlacement(index: index, row: row, column: column, span: span))
                    column += span.columns
                    break
                }
                column += 1
            }
        }
        let rows = placements.map { $0.row + $0.span.rows }.max() ?? 0
        return GridLayout(rows: rows, columns: columns, cardWidth: cardWidth,
                          cardHeight: cardHeight, placements: placements)
    }

    public var contentHeight: Double {
        rows > 0 ? Double(rows) * cardHeight + Double(rows - 1) * Self.spacing : 0
    }

    public func width(for placement: GridPlacement) -> Double {
        Double(placement.span.columns) * cardWidth + Double(placement.span.columns - 1) * Self.spacing
    }

    public func height(for placement: GridPlacement) -> Double {
        Double(placement.span.rows) * cardHeight + Double(placement.span.rows - 1) * Self.spacing
    }

    public func x(for placement: GridPlacement) -> Double {
        Double(placement.column) * (cardWidth + Self.spacing)
    }

    public func y(for placement: GridPlacement) -> Double {
        Double(placement.row) * (cardHeight + Self.spacing)
    }

    /// Items in row-major order, so that scrolling down reveals later sessions.
    public func rowsOf<T>(_ items: [T]) -> [[T]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }

    private struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    private static func cells(row: Int, column: Int, span: GridSpan) -> Set<Cell> {
        var cells = Set<Cell>()
        for r in row..<(row + span.rows) {
            for c in column..<(column + span.columns) {
                cells.insert(Cell(row: r, column: c))
            }
        }
        return cells
    }
}

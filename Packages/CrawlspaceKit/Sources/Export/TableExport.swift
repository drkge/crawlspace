import Foundation
import Storage
import libxlsxwriter

public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case csv
    case xlsx

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .xlsx: "Excel Workbook"
        }
    }
}

public enum ExportError: LocalizedError {
    case couldNotCreateFile(URL)
    case workbookFailed(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateFile(let url): "Couldn't create \(url.lastPathComponent)."
        case .workbookFailed(let message): "Excel export failed: \(message)."
        }
    }
}

/// Exports a table of URLs. Rows are streamed in batches so exporting a million-row view never
/// holds more than a batch in memory.
public enum TableExport {
    public static let batchSize = 2_000
    /// Excel's hard limits.
    static let maxRowsPerSheet = 1_048_575
    static let maxCharactersPerCell = 32_767

    public static func export(
        store: CrawlStore,
        ids: [Int64],
        columns: [URLColumn],
        format: ExportFormat,
        to url: URL,
        sheetName: String = "URLs",
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        try export(store: store, ids: ids, columns: columns.asTableColumns, format: format, to: url,
                   sheetName: sheetName, progress: progress)
    }

    public static func export(
        store: CrawlStore,
        ids: [Int64],
        columns: [URLTableColumn],
        format: ExportFormat,
        to url: URL,
        sheetName: String = "URLs",
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        switch format {
        case .csv: try exportCSV(store: store, ids: ids, columns: columns, to: url, progress: progress)
        case .xlsx: try exportXLSX(store: store, ids: ids, columns: columns, to: url, sheetName: sheetName, progress: progress)
        }
    }

    private static func forEachBatch(
        store: CrawlStore, ids: [Int64], needsExtractions: Bool, progress: (@Sendable (Double) -> Void)?,
        body: ([URLRow], [Int64: [String: String]]) throws -> Void
    ) throws {
        var done = 0
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let slice = Array(ids[start..<min(start + batchSize, ids.count)])
            let extractions = needsExtractions ? try store.extractionValues(ids: slice) : [:]
            try body(try store.rows(ids: slice), extractions)
            done += slice.count
            progress?(Double(done) / Double(max(ids.count, 1)))
        }
    }

    private static func needsExtractions(_ columns: [URLTableColumn]) -> Bool {
        columns.contains { if case .extraction = $0 { true } else { false } }
    }

    // MARK: - CSV (RFC 4180, UTF-8 with BOM so Excel detects the encoding)

    private static func exportCSV(
        store: CrawlStore, ids: [Int64], columns: [URLTableColumn], to url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExportError.couldNotCreateFile(url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = Data([0xEF, 0xBB, 0xBF])
        buffer.append(contentsOf: Data(line(columns.map(\.title)).utf8))

        try forEachBatch(store: store, ids: ids, needsExtractions: needsExtractions(columns), progress: progress) { rows, extractions in
            for row in rows {
                let values = extractions[row.id] ?? [:]
                buffer.append(contentsOf: Data(line(columns.map { field($0.value(for: row, extractions: values)) }).utf8))
                if buffer.count > 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    private static func field(_ value: URLColumn.Value) -> String {
        switch value {
        case .empty: ""
        case .text(let text): text
        case .integer(let number): String(number)
        case .decimal(let number): String(format: "%.1f", number)
        }
    }

    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - XLSX

    private static func exportXLSX(
        store: CrawlStore, ids: [Int64], columns: [URLTableColumn], to url: URL, sheetName: String,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        try? FileManager.default.removeItem(at: url)
        var options = lxw_workbook_options()
        options.constant_memory = 1  // stream rows to disk instead of holding the sheet in memory
        options.use_zip64 = 1
        guard let workbook = workbook_new_opt(url.path, &options) else {
            throw ExportError.couldNotCreateFile(url)
        }

        let header = workbook_add_format(workbook)
        format_set_bold(header)
        format_set_bg_color(header, 0xF0F0F0)

        var sheet: UnsafeMutablePointer<lxw_worksheet>?
        var sheetIndex = 0
        var rowIndex: UInt32 = 0

        func startSheet() throws {
            sheetIndex += 1
            let name = sheetIndex == 1 ? sheetName : "\(sheetName) (\(sheetIndex))"
            sheet = workbook_add_worksheet(workbook, name)
            guard let sheet else { throw ExportError.workbookFailed("couldn't add sheet \(name)") }
            for (index, column) in columns.enumerated() {
                let position = UInt16(index)
                worksheet_write_string(sheet, 0, position, column.title, header)
                worksheet_set_column(sheet, position, position, min(column.defaultWidth / 7, 80), nil)
            }
            worksheet_freeze_panes(sheet, 1, 0)
            worksheet_autofilter(sheet, 0, 0, 0, UInt16(max(columns.count - 1, 0)))
            rowIndex = 1
        }

        try startSheet()
        try forEachBatch(store: store, ids: ids, needsExtractions: needsExtractions(columns), progress: progress) { rows, extractions in
            for row in rows {
                if rowIndex >= maxRowsPerSheet { try startSheet() }
                let values = extractions[row.id] ?? [:]
                for (index, column) in columns.enumerated() {
                    let position = UInt16(index)
                    switch column.value(for: row, extractions: values) {
                    case .empty:
                        break
                    case .text(let text):
                        worksheet_write_string(sheet, rowIndex, position, String(text.prefix(maxCharactersPerCell)), nil)
                    case .integer(let number):
                        worksheet_write_number(sheet, rowIndex, position, Double(number), nil)
                    case .decimal(let number):
                        worksheet_write_number(sheet, rowIndex, position, number, nil)
                    }
                }
                rowIndex += 1
            }
        }

        let result = workbook_close(workbook)
        if result != LXW_NO_ERROR {
            throw ExportError.workbookFailed(String(cString: lxw_strerror(result)))
        }
    }
}

import SwiftUI

/// Block-level Markdown model for the notes preview. Parsing lives here, out
/// of the view, so the tests can pin it down without rendering anything.
///
/// Scope: the constructs Claude's notes actually use (headings, bullet and
/// numbered lists, quotes, fenced code, rules, GFM pipe tables, paragraphs) —
/// not a full CommonMark implementation. Inline styles (bold, italic, `code`,
/// links) are delegated to `AttributedString(markdown:)` at render time.
enum MarkdownBlocks {
    /// Column alignment requested by a table's delimiter row (`:--`, `:-:`,
    /// `--:`). `nil` = unspecified, which renders leading.
    enum ColumnAlignment: Equatable { case leading, center, trailing }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(number: String, indent: Int, text: String)
        case quote(text: String)
        case code(text: String)
        case rule
        case paragraph(text: String)
        /// `rows` are padded/truncated to `headers.count` at parse time, so the
        /// renderer never has to reason about ragged input.
        case table(headers: [String], alignments: [ColumnAlignment?], rows: [[String]])
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]? = nil   // non-nil while inside a ``` fence

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: paragraph.joined(separator: " ")))
            paragraph = []
        }

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            i += 1
            let line = raw.trimmingCharacters(in: .whitespaces)

            if var code = codeLines {
                if line.hasPrefix("```") {
                    blocks.append(.code(text: code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    code.append(raw)
                    codeLines = code
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                codeLines = []
                continue
            }
            if line.isEmpty { flushParagraph(); continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level,
                                           text: String(line.dropFirst(level + 1))))
                    continue
                }
            }
            // Tables are checked before the rule, because a delimiter row of a
            // single-column table (`|---|`) would otherwise have to fight it.
            // Detection needs the *next* line, which is why this loop is
            // index-based rather than a plain `for … in lines`.
            if line.contains("|"), i < lines.count,
               let alignments = alignmentRow(lines[i]) {
                let headers = splitRow(line)
                if headers.count == alignments.count, !headers.isEmpty {
                    flushParagraph()
                    i += 1   // consume the delimiter row
                    var rows: [[String]] = []
                    while i < lines.count {
                        let body = lines[i].trimmingCharacters(in: .whitespaces)
                        guard body.contains("|") else { break }
                        i += 1
                        var cells = splitRow(body)
                        // Ragged rows are normalised here so the renderer can
                        // assume a rectangle (GFM does the same).
                        if cells.count > headers.count {
                            cells = Array(cells.prefix(headers.count))
                        } else {
                            cells += Array(repeating: "", count: headers.count - cells.count)
                        }
                        rows.append(cells)
                    }
                    blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                blocks.append(.quote(text: String(line.dropFirst(min(2, line.count)))))
                continue
            }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."),
               line.startIndex < dot,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                flushParagraph()
                blocks.append(.numbered(number: String(line[line.startIndex..<dot]),
                                        indent: indent,
                                        text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(line)
        }
        if let code = codeLines {   // unterminated fence: render what we have
            blocks.append(.code(text: code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Pipe tables

    /// Splits one table row into trimmed cells, honouring `\|` escapes and
    /// dropping the empty cells the optional outer pipes produce.
    static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                // Only `\|` is a Markdown escape here; anything else keeps its
                // backslash so paths and regexes survive intact.
                if ch != "|" { cur.append("\\") }
                cur.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if escaped { cur.append("\\") }
        cells.append(cur)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns the per-column alignments if `line` is a table delimiter row
    /// (`|---|:--:|`), `nil` if it is anything else.
    static func alignmentRow(_ line: String) -> [ColumnAlignment?]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var out: [ColumnAlignment?] = []
        for cell in cells {
            var body = Substring(cell)
            let left = body.hasPrefix(":")
            if left { body = body.dropFirst() }
            let right = body.hasSuffix(":")
            if right { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : left ? .leading : right ? .trailing : nil)
        }
        return out
    }
}

/// Read-only rendered view of the active note. Same margins and serif body as
/// `NotesEditor`, so toggling edit ⇄ preview does not make the text jump.
struct MarkdownPreview: View {
    let markdown: String
    var placeholder: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()),
                            id: \.offset) { _, block in
                        render(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 29)
            .padding(.vertical, 24)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 14, design: .serif))
                .lineSpacing(4)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text))
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(4)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .numbered(let number, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(inline(text))
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(4)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(.quaternary).frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        case .code(let text):
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        case .rule:
            Rectangle().fill(.separator).frame(height: 1).padding(.vertical, 4)
        case .table(let headers, let alignments, let rows):
            table(headers: headers, alignments: alignments, rows: rows)
        }
    }

    /// A `Grid` rather than nested `HStack`s: columns must line up across rows,
    /// and `Grid` sizes each column on its widest cell while still letting a
    /// long cell wrap when the panel is narrow (no horizontal scroller, which
    /// would fight the vertical one this view already has).
    ///
    /// Column alignment is declared once, on the header row
    /// (`gridColumnAlignment` applies to the whole column).
    private func table(headers: [String],
                       alignments: [MarkdownBlocks.ColumnAlignment?],
                       rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { i, cell in
                    tableCell(cell, alignment: alignment(alignments, i), weight: .semibold)
                        .gridColumnAlignment(horizontal(alignment(alignments, i)))
                }
            }
            Divider().gridCellColumns(max(1, headers.count))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        tableCell(cell, alignment: alignment(alignments, i), weight: .regular)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String,
                           alignment: MarkdownBlocks.ColumnAlignment?,
                           weight: Font.Weight) -> some View {
        Text(inline(text))
            .font(.system(size: 13.5, weight: weight, design: .serif))
            .lineSpacing(3)
            .multilineTextAlignment(textAlignment(alignment))
            // Lets a long cell grow downwards instead of being clipped to one
            // line when the grid has to squeeze its column.
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Rows are normalised to the header's width at parse time, but the
    /// delimiter row is what sizes `alignments` — stay total anyway.
    private func alignment(_ alignments: [MarkdownBlocks.ColumnAlignment?],
                           _ i: Int) -> MarkdownBlocks.ColumnAlignment? {
        alignments.indices.contains(i) ? alignments[i] : nil
    }

    private func horizontal(_ a: MarkdownBlocks.ColumnAlignment?) -> HorizontalAlignment {
        switch a {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func textAlignment(_ a: MarkdownBlocks.ColumnAlignment?) -> TextAlignment {
        switch a {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 15.5
        default: return 14
        }
    }

    /// Inline Markdown (bold, italic, code spans, links) via Foundation's
    /// parser; falls back to the raw text if it rejects the line.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    }
}

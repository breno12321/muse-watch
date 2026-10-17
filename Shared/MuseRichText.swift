#if os(iOS) || os(watchOS)
import SwiftUI

/// Native, dependency-free Markdown for Muse replies, including streaming text.
/// Inherits the surrounding bubble's text color and font.
struct MuseRichText: View {
    private let blocks: [MuseMarkdown.Block]

    init(text: String) { blocks = MuseMarkdown(text).blocks }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        #if os(iOS)
        .textSelection(.enabled)
        #endif
    }

    @ViewBuilder
    private func blockView(_ block: MuseMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
        case .heading(let level):
            inline(block.text)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 3)
        case .listItem(let marker, let depth, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .imageScale(.small)
                        .accessibilityLabel(checked ? "Completed" : "Not completed")
                } else {
                    Text(verbatim: marker).foregroundStyle(.secondary)
                }
                inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 8)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.6)).frame(width: 2)
                inline(block.text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .code(let language):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(verbatim: language).font(.caption2).foregroundStyle(.secondary)
                }
                Text(verbatim: block.text)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        case .divider:
            Divider().padding(.vertical, 2)
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func table(headers: [String], rows: [[String]]) -> some View {
        #if os(watchOS)
        // Label/value cards avoid a horizontal scroll inside the vertical chat.
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                        VStack(alignment: .leading, spacing: 1) {
                            inline(header).font(.caption2).bold().foregroundStyle(.secondary)
                            inline(row[column])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            if rows.isEmpty {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in inline(header).bold() }
            }
        }
        #else
        // Equal-width, wrapping columns fit the phone bubble without clipping.
        VStack(alignment: .leading, spacing: 6) {
            tableRow(headers, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                tableRow(row, header: false)
            }
        }
        .padding(8)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        #endif
    }

    #if os(iOS)
    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell).fontWeight(header ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    #endif

    private func inline(_ source: String) -> Text {
        var value = MuseMarkdown.inline(source)
        for run in value.runs {
            if run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]?.contains(.code) == true {
                value[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(.body, design: .monospaced)
            }
        }
        return Text(value)
    }

    private func headingFont(_ level: Int) -> Font {
        #if os(watchOS)
        .system(level <= 2 ? .body : .callout, design: .rounded, weight: .semibold)
        #else
        .system(level == 1 ? .title3 : level == 2 ? .headline : .subheadline, weight: .semibold)
        #endif
    }
}
#endif

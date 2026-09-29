import SwiftUI

/// Plain-Markdown-source editor for the active note (v1: source, not WYSIWYG).
///
/// `onEdit` fires only for edits coming from the text view — deliberately *not*
/// via `onChange(of: text)`, which would also fire when the parent swaps the
/// text (meeting switch, note-level switch) and would wrongly flag the note as
/// hand-edited. The setter assigns the new value verbatim and synchronously, so
/// the insertion point is not disturbed while typing fast.
struct NotesEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var onEdit: (String) -> Void

    init(text: Binding<String>, placeholder: String = "", onEdit: @escaping (String) -> Void) {
        self._text = text
        self.placeholder = placeholder
        self.onEdit = onEdit
    }

    private var proxy: Binding<String> {
        Binding(
            get: { text },
            set: { new in
                guard new != text else { return }
                text = new
                onEdit(new)
            }
        )
    }

    var body: some View {
        // TextEditor scrolls on its own; wrapping it in a ScrollView produces
        // nested scrollers and a text view that cannot reach its own bottom.
        TextEditor(text: proxy)
            .font(.system(size: 14, design: .serif))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 29)
                        .padding(.vertical, 28)
                        .allowsHitTesting(false)
                }
            }
    }
}

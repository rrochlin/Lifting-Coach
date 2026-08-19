import SwiftUI

/// The one sheet for typing a note, wherever a note is typed.
///
/// There were two of these — the tracker's `NoteEditorSheet` and the planner's
/// `PlannerNoteSheet` — identical but for their section labels, and History's
/// editor would have made a third. Same reasoning as `ExercisePicker`: a
/// duplicated control doesn't stay duplicated, it drifts, and the copy that
/// misses a redesign is the one you find in a screenshot months later.
///
/// `context` is what the note sits beside and can't change — the *programmed*
/// note on a set the lifter is annotating. Shown because a note written without
/// what it responds to in view is half a record.
struct NoteSheet: View {
    let title: String
    /// The label over the editable field: "your note", "programmed note".
    var editorLabel: String = "your note"
    /// Read-only context shown above, when there is any.
    var context: (label: String, text: String)?
    @Binding var note: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let context, !context.text.isEmpty {
                    SectionLabel(text: context.label, accent: Theme.inkFaint)
                    Text(context.text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkMuted)
                }

                SectionLabel(text: editorLabel, accent: Theme.signal)
                TextEditor(text: $note)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()
            }
            .padding(16)
            .background(Theme.void)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

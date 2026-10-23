import SwiftUI

/// Builds a Navidrome smart playlist: rules (field · operator · value), match all/any, order and limit.
struct SmartPlaylistSheet: View {
    @Environment(LibraryRepository.self) private var library
    @Environment(UIState.self) private var ui: UIState?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var rules = SmartPlaylistRules()
    @State private var isSaving = false
    @State private var createdCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    Picker("Match", selection: $rules.matchAll) {
                        Text("All Rules").tag(true)
                        Text("Any Rule").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                ForEach($rules.conditions) { $condition in
                    Section {
                        SmartConditionEditor(condition: $condition)
                        if rules.conditions.count > 1 {
                            Button("Remove Rule", role: .destructive) {
                                withAnimation(.snappy) {
                                    rules.conditions.removeAll { $0.id == condition.id }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        withAnimation(.snappy) { rules.conditions.append(SmartPlaylistCondition()) }
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle.fill")
                    }
                }

                Section("Order") {
                    Picker("Sort By", selection: $rules.sort) {
                        ForEach(SmartPlaylistSort.allCases) { Text($0.title).tag($0) }
                    }
                    if rules.sort != .random {
                        Toggle("Descending", isOn: $rules.descending)
                    }
                    Stepper(value: $rules.limit, in: 10...1000, step: 10) {
                        LabeledContent("Limit", value: KMFormat.songCount(rules.limit))
                    }
                }

                Section {
                    Text("Navidrome keeps smart playlists up to date as your library changes.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("New Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create", role: .confirm) { create() }
                            .disabled(trimmedName.isEmpty || !rules.isValid)
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: createdCount)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        isSaving = true
        Task {
            if (try? await library.createSmartPlaylist(name: trimmedName, rules: rules)) != nil {
                createdCount += 1
                ui?.showToast("Created “\(trimmedName)”")
                dismiss()
            }
            isSaving = false
        }
    }
}

private struct SmartConditionEditor: View {
    @Binding var condition: SmartPlaylistCondition

    var body: some View {
        Picker("Field", selection: $condition.field) {
            ForEach(SmartPlaylistField.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: condition.field) { _, field in
            if !field.operators.contains(condition.op), let first = field.operators.first {
                condition.op = first
            }
        }

        if condition.field.operators.count > 1 {
            Picker("Condition", selection: $condition.op) {
                ForEach(condition.field.operators) { Text($0.title).tag($0) }
            }
        }

        switch condition.field.kind {
        case .text:
            TextField("Value", text: $condition.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number, .days:
            numberField(condition.op == .inTheRange ? "From" : "Value", value: $condition.number)
            if condition.op == .inTheRange {
                numberField("To", value: $condition.upperNumber)
            }
        case .flag:
            Toggle("Loved", isOn: $condition.flag)
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

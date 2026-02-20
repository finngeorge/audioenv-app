import SwiftUI

/// Smart-playlist-style visual query builder with filter rows.
struct CommandVisualBuilder: View {
    @Binding var query: Query
    var onQueryChanged: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visual Builder")
                .font(.headline)
                .foregroundColor(.secondary)

            // Entity type picker
            entityTypePicker

            // Combination toggle
            if query.filters.count > 1 {
                combinationToggle
            }

            // Filter rows
            ForEach(Array(query.filters.enumerated()), id: \.element.id) { index, filter in
                filterRow(index: index, filter: filter)
            }

            // Add filter button
            Button {
                let defaultField = query.entityType.availableFields.first ?? .name
                let defaultOp = defaultField.availableOperators.first ?? .equals
                query.filters.append(QueryFilter(field: defaultField, op: defaultOp, value: ""))
                onQueryChanged?()
            } label: {
                Label("Add Filter", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Entity Type Picker

    private var entityTypePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entity Type")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                ForEach(QueryEntityType.allCases) { type in
                    Button {
                        query.entityType = type
                        // Clear filters that don't apply to new entity type
                        query.filters = query.filters.filter { type.availableFields.contains($0.field) }
                        onQueryChanged?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: type.icon)
                                .font(.caption)
                            Text(type.label)
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(query.entityType == type ? Color.blue : Color.secondary.opacity(0.1))
                        .foregroundColor(query.entityType == type ? .white : .primary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Combination Toggle

    private var combinationToggle: some View {
        HStack(spacing: 8) {
            Text("Match")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Combination", selection: Binding(
                get: { query.combination },
                set: { query.combination = $0; onQueryChanged?() }
            )) {
                Text("All (AND)").tag(FilterCombination.all)
                Text("Any (OR)").tag(FilterCombination.any)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }

    // MARK: - Filter Row

    private func filterRow(index: Int, filter: QueryFilter) -> some View {
        HStack(spacing: 8) {
            // Field picker
            Picker("Field", selection: Binding(
                get: { query.filters[index].field },
                set: {
                    query.filters[index].field = $0
                    // Reset operator if current one isn't available for new field
                    let availableOps = $0.availableOperators
                    if !availableOps.contains(query.filters[index].op) {
                        query.filters[index].op = availableOps.first ?? .equals
                    }
                    onQueryChanged?()
                }
            )) {
                ForEach(query.entityType.availableFields) { field in
                    Text(field.label).tag(field)
                }
            }
            .frame(width: 120)

            // Operator picker
            Picker("Operator", selection: Binding(
                get: { query.filters[index].op },
                set: { query.filters[index].op = $0; onQueryChanged?() }
            )) {
                ForEach(query.filters[index].field.availableOperators) { op in
                    Text(op.label).tag(op)
                }
            }
            .frame(width: 120)

            // Value input
            valueInput(index: index, filter: filter)

            // Remove button
            Button {
                query.filters.remove(at: index)
                onQueryChanged?()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Value Input

    @ViewBuilder
    private func valueInput(index: Int, filter: QueryFilter) -> some View {
        switch filter.field {
        case .format:
            formatPicker(index: index)

        case .bpm, .duration, .sampleRate:
            HStack(spacing: 4) {
                TextField("Value", text: Binding(
                    get: { query.filters[index].value },
                    set: { query.filters[index].value = $0; onQueryChanged?() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)

                if filter.op == .between {
                    Text("and")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Max", text: Binding(
                        get: { query.filters[index].secondaryValue ?? "" },
                        set: { query.filters[index].secondaryValue = $0; onQueryChanged?() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }
            }

        case .modifiedDate:
            HStack(spacing: 4) {
                TextField("e.g. 7d, 30d, 1y", text: Binding(
                    get: { query.filters[index].value },
                    set: { query.filters[index].value = $0; onQueryChanged?() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            }

        default:
            TextField("Value", text: Binding(
                get: { query.filters[index].value },
                set: { query.filters[index].value = $0; onQueryChanged?() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120)
        }
    }

    @ViewBuilder
    private func formatPicker(index: Int) -> some View {
        let formats: [String] = {
            switch query.entityType {
            case .plugins: return ["audioUnit", "vst", "vst3", "aax"]
            case .projects: return ["ableton", "logic", "proTools"]
            case .bounces: return ["wav", "mp3", "aiff", "flac"]
            case .collections: return []
            }
        }()

        if formats.isEmpty {
            TextField("Value", text: Binding(
                get: { query.filters[index].value },
                set: { query.filters[index].value = $0; onQueryChanged?() }
            ))
            .textFieldStyle(.roundedBorder)
        } else {
            Picker("Format", selection: Binding(
                get: { query.filters[index].value },
                set: { query.filters[index].value = $0; onQueryChanged?() }
            )) {
                Text("Any").tag("")
                ForEach(formats, id: \.self) { fmt in
                    Text(fmt).tag(fmt)
                }
            }
            .frame(width: 120)
        }
    }
}

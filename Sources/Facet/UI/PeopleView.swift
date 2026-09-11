import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var state: AppState
    @State private var showUnnamed = true
    @State private var renaming: PersonRow?
    @State private var draftName = ""
    @State private var mergeSource: PersonRow?

    private var shown: [PersonRow] {
        state.people
            .filter { showUnnamed || $0.isNamed }
            .sorted { a, b in
                if a.isNamed != b.isNamed { return a.isNamed }
                return a.faceCount > b.faceCount
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("^[\(shown.count) person](inflect: true)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show unnamed", isOn: $showUnnamed).toggleStyle(.switch).controlSize(.mini)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)

            if shown.isEmpty {
                NoPeopleView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16)], spacing: 18) {
                        ForEach(shown) { person in
                            Button { state.route = .person(person.id) } label: {
                                PersonTile(person: person)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(person.displayName), \(person.faceCount) photos")
                            .contextMenu { menu(for: person) }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .onAppear { state.reloadPeople() }
        .sheet(item: $renaming) { person in
            RenameSheet(person: person, name: $draftName) { newName in
                state.rename(person: person.id, to: newName)
                renaming = nil
            } onCancel: { renaming = nil }
        }
        .sheet(item: $mergeSource) { source in
            MergeSheet(source: source, candidates: state.people.filter { $0.id != source.id }) { target in
                state.store.merge(person: source.id, into: target.id)
                state.reloadPeople()
                mergeSource = nil
            } onCancel: { mergeSource = nil }
        }
    }

    @ViewBuilder
    private func menu(for person: PersonRow) -> some View {
        Button(person.isNamed ? "Rename…" : "Name this person…") {
            draftName = person.name ?? ""
            renaming = person
        }
        Button("Merge into…") { mergeSource = person }
        Divider()
        Button("Show photos") { state.route = .person(person.id) }
        Button("Add to filter") { state.togglePersonFilter(person.id); state.route = .library }
        Divider()
        Button("Hide this person", role: .destructive) {
            state.store.setHidden(person: person.id, true)
            state.reloadPeople()
        }
    }
}

struct PersonTile: View {
    @EnvironmentObject var state: AppState
    let person: PersonRow

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if let cover = person.coverFaceID {
                    ThumbImage(cached: state.store.faceThumbnailURL(for: cover))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "person.fill").font(.title).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 118, height: 118)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))

            Text(person.displayName)
                .font(.callout.weight(person.isNamed ? .medium : .regular))
                .foregroundStyle(person.isNamed ? .primary : .secondary)
                .lineLimit(1)
            Text("^[\(person.faceCount) photo](inflect: true)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct NoPeopleView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 42)).foregroundStyle(.tertiary)
            Text("No people yet").font(.title3.weight(.medium))
            Text(state.indexer.isBusy
                 ? "Facet is still analysing your photos. People appear as faces are grouped."
                 : "Import a folder with photos of people, and they'll be grouped here automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RenameSheet: View {
    let person: PersonRow
    @Binding var name: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name this person").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { onSave(name) }
            Text("Naming a person keeps their group stable as you add more photos.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

struct MergeSheet: View {
    let source: PersonRow
    let candidates: [PersonRow]
    var onMerge: (PersonRow) -> Void
    var onCancel: () -> Void
    @State private var selected: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(source.displayName)” into…").font(.headline)
            Text("The two groups become one. This is the fix when the same person was split in two.")
                .font(.caption).foregroundStyle(.secondary)
            List(candidates, selection: $selected) { p in
                HStack {
                    Text(p.displayName)
                    Spacer()
                    Text("\(p.faceCount)").foregroundStyle(.secondary)
                }
                .tag(p.id)
            }
            .frame(width: 320, height: 260)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let id = selected, let target = candidates.first(where: { $0.id == id }) { onMerge(target) }
                }
                .disabled(selected == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

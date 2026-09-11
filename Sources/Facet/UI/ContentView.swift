import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var viewerIndex: Int?

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                Group {
                    switch state.route {
                    case .people:
                        PeopleView()
                    case .person(let id):
                        PersonDetailView(personID: id)
                    default:
                        PhotoGridView(onOpen: { viewerIndex = $0 })
                    }
                }

                if let idx = viewerIndex, state.assets.indices.contains(idx) {
                    PhotoViewer(index: idx,
                                onClose: { viewerIndex = nil },
                                onNavigate: { viewerIndex = $0 })
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .toolbar { toolbarContent }
            .searchable(text: $state.searchText,
                        placement: .toolbar,
                        prompt: "Search photos — try “beach sunset”")
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch state.route {
        case .library: return "All Photos"
        case .people: return "People"
        case .person(let id): return state.people.first { $0.id == id }?.displayName ?? "Person"
        case .folder(let id): return state.folders.first { $0.id == id }?.displayName ?? "Folder"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if state.searching { ProgressView().controlSize(.small).scaleEffect(0.6) }
        }
        ToolbarItemGroup {
            if case .people = state.route {} else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Slider(value: $state.thumbSize, in: 96...360)
                    .frame(width: 110)
                    .help("Thumbnail size")
            }
        }
    }
}

/// Chips describing every active filter, with one-click removal.
struct FilterBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let hasFilters = !state.requiredPeople.isEmpty || !state.excludedPeople.isEmpty
            || state.similarFaceLabel != nil
        if hasFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let label = state.similarFaceLabel {
                        Chip(text: "Looks like \(label)", systemImage: "wand.and.stars", tint: .purple) {
                            state.clearSimilar()
                        }
                    }
                    ForEach(state.requiredPeople, id: \.self) { id in
                        Chip(text: name(id), systemImage: "person.fill", tint: .accentColor) {
                            state.togglePersonFilter(id)
                        }
                    }
                    ForEach(state.excludedPeople, id: \.self) { id in
                        Chip(text: "without \(name(id))", systemImage: "person.slash", tint: .red) {
                            state.toggleExcludePerson(id)
                        }
                    }
                    Spacer()
                    Button("Clear") {
                        state.requiredPeople = []
                        state.excludedPeople = []
                        state.clearSimilar()
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    private func name(_ id: Int64) -> String {
        state.people.first { $0.id == id }?.displayName ?? "Person"
    }
}

struct Chip: View {
    let text: String
    var systemImage: String
    var tint: Color = .accentColor
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
    }
}

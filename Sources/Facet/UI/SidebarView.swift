import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.route },
            set: { if let r = $0 { state.route = r } }
        )) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled").tag(Route.library)
                Label("People", systemImage: "person.2").tag(Route.people)
            }

            Section {
                ForEach(state.folders) { folder in
                    Label(folder.displayName, systemImage: "folder")
                        .help(folder.path)
                        .tag(Route.folder(folder.id))
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                            }
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                state.removeFolder(folder.id)
                            }
                        }
                }
                Button {
                    state.addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Folders")
            }

            if !namedPeople.isEmpty {
                Section("Named") {
                    ForEach(namedPeople) { p in
                        Label(p.displayName, systemImage: "person.crop.circle")
                            .badge(p.faceCount)
                            .tag(Route.person(p.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .safeAreaInset(edge: .bottom) { IndexStatusBar() }
    }

    private var namedPeople: [PersonRow] {
        state.people.filter(\.isNamed).sorted { $0.displayName < $1.displayName }
    }
}

struct IndexStatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        IndexStatusContent(indexer: state.indexer)
    }
}

struct IndexStatusContent: View {
    @ObservedObject var indexer: Indexer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                if indexer.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                }
                Text(indexer.phase.label)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if indexer.isBusy {
                    Button {
                        indexer.pause()
                    } label: {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.plain)
                } else if indexer.phase == .paused {
                    Button {
                        indexer.start()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            if indexer.isBusy, indexer.total > 0 {
                ProgressView(value: indexer.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(indexer.done) of \(indexer.total)")
                    Spacer()
                    Text(indexer.remainingText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let err = indexer.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

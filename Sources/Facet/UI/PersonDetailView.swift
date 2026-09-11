import SwiftUI

struct PersonDetailView: View {
    @EnvironmentObject var state: AppState
    let personID: Int64

    @State private var person: PersonRow?
    @State private var faces: [FaceRow] = []
    @State private var draftName = ""
    @State private var showFaceStrip = false
    @State private var viewerIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            if showFaceStrip { faceStrip }
            Divider()
            PhotoGridView(onOpen: { viewerIndex = $0 })
        }
        .overlay {
            if let idx = viewerIndex, state.assets.indices.contains(idx) {
                PhotoViewer(index: idx, onClose: { viewerIndex = nil }, onNavigate: { viewerIndex = $0 })
            }
        }
        .task(id: personID) { reload() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let cover = person?.coverFaceID {
                    ThumbImage(cached: state.store.faceThumbnailURL(for: cover))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 62, height: 62)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                TextField("Add a name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { save() }
                    .frame(maxWidth: 320)
                Text("^[\(state.assets.count) photo](inflect: true) · ^[\(faces.count) face](inflect: true)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showFaceStrip.toggle()
            } label: {
                Label("Review faces", systemImage: "square.grid.3x3")
            }
            .help("Check the faces grouped into this person and remove any that don't belong")

            Menu {
                Button("Save name") { save() }
                Button("Use filter in All Photos") {
                    state.togglePersonFilter(personID)
                    state.route = .library
                }
                Divider()
                Button("Hide this person", role: .destructive) {
                    state.store.setHidden(person: personID, true)
                    state.reloadPeople()
                    state.route = .people
                }
                Button("Ungroup (delete person)", role: .destructive) {
                    state.store.deletePerson(personID)
                    state.reloadPeople()
                    state.route = .people
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Lets the user prune faces that were grouped in by mistake.
    private var faceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(faces) { face in
                    VStack(spacing: 3) {
                        ThumbImage(cached: state.store.faceThumbnailURL(for: face.id))
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                if face.confirmed {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption2).foregroundStyle(.green)
                                        .padding(2)
                                }
                            }
                        Text(String(format: "%.2f", face.quality))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contextMenu {
                        Button("Use as cover") {
                            state.store.setCover(person: personID, faceID: face.id)
                            reload(); state.reloadPeople()
                        }
                        Button("Confirm this is \(person?.displayName ?? "them")") {
                            state.store.assign(faceID: face.id, personID: personID, confirmed: true)
                            reload()
                        }
                        Divider()
                        Button("Not this person", role: .destructive) {
                            // Detaching marks it clustered so it isn't silently re-added.
                            state.store.assign(faceID: face.id, personID: nil, confirmed: false)
                            reload(); state.reloadPeople(); state.refresh()
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func reload() {
        person = state.store.person(id: personID)
        faces = state.store.faces(forPerson: personID, limit: 400)
        draftName = person?.name ?? ""
    }

    private func save() {
        state.rename(person: personID, to: draftName)
        reload()
    }
}

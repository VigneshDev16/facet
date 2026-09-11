import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var clusterThreshold: Double = Double(Tuning.defaultClusterThreshold)
    @State private var searchThreshold: Double = Double(Tuning.defaultSearchThreshold)
    @State private var working = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            matching.tabItem { Label("Face Matching", systemImage: "person.crop.square") }
            SharingSettingsView().tabItem { Label("Sharing", systemImage: "iphone.and.arrow.forward") }
        }
        .frame(width: 560, height: 460)
        .onAppear {
            clusterThreshold = state.store.doubleSetting("clusterThreshold", default: Double(Tuning.defaultClusterThreshold))
            searchThreshold = state.store.doubleSetting("searchThreshold", default: Double(Tuning.defaultSearchThreshold))
        }
    }

    private var general: some View {
        Form {
            LabeledContent("Photos indexed", value: "\(state.store.assetCount)")
            LabeledContent("Faces found", value: "\(state.store.faceCount)")
            LabeledContent("People", value: "\(state.people.count)")
            LabeledContent("Library", value: state.store.root.path)
                .textSelection(.enabled)
            Divider()
            Button("Rescan folders for new photos") { state.indexer.start() }
            Button("Re-analyse every photo") {
                state.indexer.reanalyseAll()
            }
            .help("Clears thumbnails, faces and search data, then rebuilds from scratch")
        }
        .formStyle(.grouped)
    }

    private var matching: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Slider(value: $clusterThreshold, in: 0.25...0.65, step: 0.01) {
                        Text("Grouping strictness")
                    } minimumValueLabel: {
                        Text("Loose").font(.caption2)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption2)
                    }
                    Text(String(format: "%.2f — ", clusterThreshold) + strictnessHint)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Grouping")
            } footer: {
                Text("Higher values split people apart rather than risk merging two different people. Calibrated default is 0.46.")
                    .font(.caption)
            }

            Section("Face search") {
                Slider(value: $searchThreshold, in: 0.15...0.60, step: 0.01) {
                    Text("Match cutoff")
                }
                Text(String(format: "%.2f", searchThreshold))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(working ? "Regrouping…" : "Regroup all people now") {
                    save()
                    working = true
                    Task.detached(priority: .userInitiated) {
                        Clusterer(store: state.store).rebuildAll()
                        await MainActor.run { working = false; state.reloadPeople(); state.refresh() }
                    }
                }
                .disabled(working)
                Text("Keeps the names you've already assigned and re-groups everything else.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: clusterThreshold) { save() }
        .onChange(of: searchThreshold) { save() }
    }

    private var strictnessHint: String {
        switch clusterThreshold {
        case ..<0.40: return "groups aggressively; may mix similar-looking people"
        case ..<0.54: return "balanced (recommended)"
        default: return "very cautious; one person may appear as several groups"
        }
    }

    private func save() {
        state.store.setSetting("clusterThreshold", String(clusterThreshold))
        state.store.setSetting("searchThreshold", String(searchThreshold))
    }
}

import SwiftUI

struct PhotoGridView: View {
    @EnvironmentObject var state: AppState
    var onOpen: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            if state.assets.isEmpty {
                EmptyLibraryView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: state.thumbSize), spacing: 6)], spacing: 6) {
                        ForEach(Array(state.assets.enumerated()), id: \.element.id) { idx, asset in
                            // A real Button rather than onTapGesture: gives each cell an
                            // AXPress action for VoiceOver and reliable hit-testing.
                            Button { onOpen(idx) } label: {
                                PhotoCell(asset: asset, side: state.thumbSize)
                            }
                                .buttonStyle(.plain)
                                .accessibilityLabel(asset.filename)
                                .contextMenu {
                                    Button("Open in Preview") { state.openExternally(asset) }
                                    Button("Reveal in Finder") { state.revealInFinder(asset) }
                                    Divider()
                                    Button("Copy Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(asset.path, forType: .string)
                                    }
                                }
                        }
                    }
                    .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(state.assets.count) photos")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
            }
        }
    }
}

struct PhotoCell: View {
    @EnvironmentObject var state: AppState
    let asset: Asset
    let side: Double

    var body: some View {
        ThumbImage(cached: state.store.thumbnailURL(for: asset.id), original: asset.url)
            .frame(width: side, height: side)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .help(asset.filename)
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: state.store.assetCount == 0 ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            if state.store.assetCount == 0 {
                Text("No photos yet").font(.title3.weight(.medium))
                Text("Import a folder and Facet will index it, find every face, and group them into people.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Import Folder…") { state.addFolder() }
                    .controlSize(.large)
            } else {
                Text("No matches").font(.title3.weight(.medium))
                Text("Try a different search, or clear the active filters.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

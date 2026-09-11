import SwiftUI
import AppKit

/// Full-window photo view with face boxes drawn over the image.
struct PhotoViewer: View {
    @EnvironmentObject var state: AppState
    let index: Int
    var onClose: () -> Void
    var onNavigate: (Int) -> Void

    @State private var image: NSImage?
    @State private var faces: [FaceRow] = []
    @State private var showFaces = true
    @FocusState private var focused: Bool

    private var asset: Asset? { state.assets.indices.contains(index) ? state.assets[index] : nil }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.96)).ignoresSafeArea()

            if let image {
                GeometryReader { geo in
                    let frame = fittedRect(imageSize: image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        if showFaces {
                            ForEach(faces) { face in
                                Button {
                                    state.findSimilar(to: face, label: personName(face) ?? "this face")
                                    onClose()
                                } label: {
                                    FaceOverlay(face: face, name: personName(face))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(personName(face).map { "Show all photos of \($0)" }
                                                    ?? "Find photos with this face")
                                .frame(width: face.box.width * frame.width,
                                       height: face.box.height * frame.height)
                                .offset(x: frame.minX + face.box.minX * frame.width,
                                        y: frame.minY + face.box.minY * frame.height)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.large)
            }

            VStack {
                header
                Spacer()
                footer
            }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { showFaces.toggle(); return .handled }
        .task(id: asset?.id) { await load() }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 1) {
                Text(asset?.filename ?? "").font(.headline).lineLimit(1)
                if let a = asset {
                    Text(a.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(isOn: $showFaces) {
                Label("\(faces.count)", systemImage: "person.crop.square")
            }
            .toggleStyle(.button)
            .help("Show detected faces (space)")

            if let a = asset {
                Button { state.revealInFinder(a) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                Button { state.openExternally(a) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in Preview")
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0)
            Text("\(index + 1) of \(state.assets.count)")
                .font(.caption).monospacedDigit()
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= state.assets.count - 1)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 18)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if state.assets.indices.contains(next) { onNavigate(next) }
    }

    private func personName(_ face: FaceRow) -> String? {
        guard let pid = face.personID else { return nil }
        return state.people.first { $0.id == pid }?.name?.nilIfEmpty
    }

    private func load() async {
        guard let asset else { return }
        faces = state.store.faces(forAsset: asset.id)
        let url = asset.url
        image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageDecoder.decode(url: url, maxPixel: 3000) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    /// Where an aspect-fit image actually lands inside the available space.
    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

struct FaceOverlay: View {
    let face: FaceRow
    let name: String?
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(hovering ? Color.accentColor : .white.opacity(0.85), lineWidth: hovering ? 2.5 : 1.5)
            .overlay(alignment: .bottom) {
                Text(name ?? "Find matches")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(name != nil ? Color.accentColor : .black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: 14)
                    .opacity(hovering || name != nil ? 1 : 0)
            }
            // strokeBorder alone only hit-tests the 1.5pt outline; make the whole box clickable.
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(name.map { "Show all photos of \($0)" } ?? "Find photos with this face")
    }
}

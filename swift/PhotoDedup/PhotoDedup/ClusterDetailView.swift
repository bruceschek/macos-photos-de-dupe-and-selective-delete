import SwiftUI
import Photos
import AppKit
import AVFoundation
import AVKit

struct ClusterDetailView: View {
    let clusterId: Int

    @State private var detail: ClusterDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showLightbox = false
    @State private var lightboxIndex = 0
    @State private var queue = DeletionQueue.shared
    @State private var showMarkError = false
    @State private var focusedIndex = 0
    @FocusState private var gridFocused: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading group…")
            } else if let detail {
                content(detail)
            }
        }
        .navigationTitle("Group #\(clusterId)")
        .navigationSubtitle(detail.map { "\($0.kind.replacingOccurrences(of: "_", with: " ").capitalized) · \($0.photos.count) photos" } ?? "")
        .toolbar { toolbar }
        .task(id: clusterId) { await load() }
        // Keyboard: ← → move the focused photo, Delete/Backspace marks it,
        // Return opens it in the lightbox.
        .focusable()
        .focused($gridFocused)
        .onKeyPress(.leftArrow)  { moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(1);  return .handled }
        .onKeyPress(.delete)     { toggleFocusedMark(); return .handled }
        .onKeyPress(.return)     { openFocused(); return .handled }
        .onChange(of: showLightbox) { _, shown in
            if !shown { gridFocused = true }   // reclaim key focus when lightbox closes
        }
        // When the batch is committed, drop the deleted rows from this grid.
        .onChange(of: queue.commitGeneration) {
            let removed = queue.lastCommitUUIDs
            detail?.photos.removeAll { removed.contains($0.uuid) }
            clampFocus()
        }
        .onChange(of: queue.lastError) { _, newValue in
            showMarkError = newValue != nil
        }
        .alert("Can't Mark Photo", isPresented: $showMarkError) {
            Button("OK") { queue.clearError() }
        } message: {
            Text(queue.lastError ?? "")
        }
        .sheet(isPresented: $showLightbox) {
            if let photos = detail?.photos {
                LightboxView(photos: photos, initialIndex: lightboxIndex)
                    .frame(minWidth: 760, minHeight: 560)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: ClusterDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(Array(detail.photos.enumerated()), id: \.element.uuid) { index, photo in
                        PhotoCard(
                            photo: photo,
                            isMarked: queue.isMarked(photo.uuid),
                            isFocused: gridFocused && focusedIndex == index,
                            onToggleMark: { toggleMark(photo) },
                            onOpen: {
                                focusedIndex = index
                                lightboxIndex = index
                                showLightbox = true
                            }
                        )
                        .id(photo.uuid)
                    }
                }
                .padding()
            }
            .onChange(of: focusedIndex) { _, index in
                guard detail.photos.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(detail.photos[index].uuid, anchor: .center)
                }
            }
        }
    }

    // MARK: - Keyboard navigation

    private func moveFocus(_ delta: Int) {
        guard let count = detail?.photos.count, count > 0 else { return }
        focusedIndex = min(max(focusedIndex + delta, 0), count - 1)
    }

    private func toggleFocusedMark() {
        guard let photos = detail?.photos, photos.indices.contains(focusedIndex) else { return }
        toggleMark(photos[focusedIndex])
    }

    private func openFocused() {
        guard let photos = detail?.photos, photos.indices.contains(focusedIndex) else { return }
        lightboxIndex = focusedIndex
        showLightbox = true
    }

    private func clampFocus() {
        guard let count = detail?.photos.count, count > 0 else { focusedIndex = 0; return }
        focusedIndex = min(focusedIndex, count - 1)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let detail, !detail.photos.isEmpty {
                let allMarked = detail.photos.allSatisfy { queue.isMarked($0.uuid) }
                Button {
                    if allMarked { unmarkAll(detail) } else { markAll(detail) }
                } label: {
                    Label(allMarked ? "Unmark All" : "Mark All",
                          systemImage: allMarked ? "square" : "checkmark.square")
                }
            }
        }
    }

    private func toggleMark(_ photo: PhotoMeta) {
        if queue.isMarked(photo.uuid) {
            queue.unmark(photo.uuid)
        } else {
            queue.mark(photo)   // sets queue.lastError → alert if it can't be deleted
        }
    }

    private func markAll(_ detail: ClusterDetail) {
        for photo in detail.photos where !queue.isMarked(photo.uuid) {
            queue.mark(photo)
        }
    }

    private func unmarkAll(_ detail: ClusterDetail) {
        for photo in detail.photos { queue.unmark(photo.uuid) }
    }

    @MainActor
    private func load() async {
        isLoading = true
        detail = nil
        focusedIndex = 0
        do {
            let loaded = try await LocalBackend.shared.cluster(id: clusterId)
            detail = loaded
            isLoading = false
            gridFocused = true
        } catch is CancellationError {
            // user navigated to another cluster; new task owns loading state
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

struct PhotoCard: View {
    let photo: PhotoMeta
    let isMarked: Bool
    var isFocused: Bool = false
    let onToggleMark: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail — tap to open lightbox
            PHAssetThumbnailView(photo: photo)
                .frame(height: 180)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }
                .overlay(alignment: .topTrailing) {
                    if isMarked {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .red)
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                // Checkbox + filename — marks the photo for batch deletion
                Toggle(isOn: Binding(get: { isMarked }, set: { _ in onToggleMark() })) {
                    Text(photo.filename)
                        .font(AppFont.base.bold())
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)

                if let originDateText {
                    Text(originDateText)
                        .font(AppFont.small)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if let w = photo.width, let h = photo.height {
                        Text("\(w)×\(h)").font(AppFont.small)
                    }
                    if photo.isRaw  { Text("RAW").font(AppFont.small).foregroundStyle(.orange) }
                    if photo.isLive { Text("LIVE").font(AppFont.small).foregroundStyle(.blue) }
                    if !photo.isLocal {
                        Image(systemName: "icloud").font(AppFont.small).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)

                Button(action: onToggleMark) {
                    Label(isMarked ? "Marked for Deletion" : "Mark for Deletion",
                          systemImage: isMarked ? "trash.fill" : "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(isMarked ? .red : .green)
                .padding(.top, 2)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(isMarked ? Color.red.opacity(0.12) : Color(.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isMarked ? Color.red : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Keyboard-focus ring, drawn outside the clip so it reads as a highlight
        // distinct from the red "marked" border.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(-3)
        )
    }

    private var originDateText: String? {
        guard let dateTaken = photo.dateTaken else { return nil }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: dateTaken))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// Loads thumbnails via PhotoKit — works for all photos including iCloud-only
struct PHAssetThumbnailView: View {
    let photo: PhotoMeta

    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?
    @State private var generation: AVAssetImageGenerator?
    @State private var isActive = false

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                let isCloudVideo = photo.filePath == nil && photo.filename.lowercased().hasSuffix(".mov")
                Color.secondary.opacity(0.08)
                    .overlay(
                        Image(systemName: isCloudVideo ? "icloud.and.arrow.down" : "photo")
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .onAppear {
            isActive = true
            startLoading()
        }
        .onDisappear { cancelLoading() }
    }

    private func startLoading() {
        // Use stored localIdentifier when available; fall back to reconstructed form for
        // assets ingested before the local_identifier migration was deployed.
        let identifier = photo.localIdentifier ?? "\(photo.uuid)/L0/001"
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else {
            print("[Thumbnail] Asset not found: \(identifier)")
            return
        }
        if asset.mediaType == .video {
            loadVideoFrame(asset: asset)
        } else {
            loadPhotoThumbnail(asset: asset)
        }
    }

    private func loadPhotoThumbnail(asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 600, height: 600),
            contentMode: .aspectFill,
            options: options
        ) { img, info in
            if let err = info?[PHImageErrorKey] as? Error {
                print("[Thumbnail] Photo error for \(photo.uuid): \(err)")
            }
            guard let img else { return }
            DispatchQueue.main.async { self.image = img }
        }
    }

    // requestAVAsset crashes with _dispatch_assert_queue_fail inside the Photos XPC
    // layer (same root cause as the performChanges crash — iCloud account access).
    // Bypass it entirely: use the file path the DB already recorded for local videos.
    // Cloud-only videos (filePath == nil) show a video-camera placeholder.
    private func loadVideoFrame(asset: PHAsset) {
        guard let path = photo.filePath else {
            print("[Thumbnail] No local file path for video \(photo.uuid); skipping")
            return
        }
        let url = URL(fileURLWithPath: path)
        let avAsset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        generation = gen

        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, result, error in
            if let error {
                print("[Thumbnail] Video frame error for \(photo.uuid): \(error)")
                return
            }
            guard result == .succeeded, let cg else { return }
            DispatchQueue.main.async {
                guard isActive else { return }
                image = NSImage(cgImage: cg, size: .zero)
                generation = nil
            }
        }
    }

    private func cancelLoading() {
        isActive = false
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
        generation?.cancelAllCGImageGeneration()
        generation = nil
    }
}

// MARK: - Lightbox

struct LightboxView: View {
    @State private var localPhotos: [PhotoMeta]
    @State private var currentIndex: Int
    @State private var queue = DeletionQueue.shared
    @State private var showMarkError = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(photos: [PhotoMeta], initialIndex: Int) {
        _localPhotos = State(initialValue: photos)
        _currentIndex = State(initialValue: initialIndex)
    }

    private var current: PhotoMeta { localPhotos[currentIndex] }

    var body: some View {
        ZStack {
            // Tapping the black backdrop (anywhere outside the photo) closes the view.
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            LightboxMediaView(photo: current)
                .id(current.uuid)
                .padding(.bottom, 72)

            // Prev / Next arrows
            HStack {
                arrowButton("chevron.left.circle.fill", action: prev)
                    .disabled(currentIndex == 0)
                Spacer()
                arrowButton("chevron.right.circle.fill", action: next)
                    .disabled(currentIndex == localPhotos.count - 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 72)

            // Bottom info + delete bar
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.filename).font(.headline).foregroundStyle(.white)
                        HStack(spacing: 8) {
                            if let ts = current.dateTaken {
                                Text(formattedDate(ts)).font(AppFont.base).foregroundStyle(.white.opacity(0.65))
                            }
                            if let w = current.width, let h = current.height {
                                Text("\(w)×\(h)").font(AppFont.base).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                    Spacer()
                    Text("\(currentIndex + 1) / \(localPhotos.count)")
                        .font(AppFont.label.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                    Button(action: openInPhotos) {
                        Label("Open in Photos", systemImage: "arrow.up.forward.app")
                            .padding(.horizontal, 4)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal this photo in the Photos app")
                    Button {
                        toggleMark()
                    } label: {
                        Label(queue.isMarked(current.uuid) ? "Marked for Deletion" : "Mark for Deletion",
                              systemImage: queue.isMarked(current.uuid) ? "trash.fill" : "trash")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(queue.isMarked(current.uuid) ? .red : .green)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
            }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow)  { prev(); return .handled }
        .onKeyPress(.rightArrow) { next(); return .handled }
        .onKeyPress(.delete)     { toggleMarkInPlace(); return .handled }
        .onKeyPress(.escape)     { dismiss(); return .handled }
        .onChange(of: queue.lastError) { _, newValue in
            showMarkError = newValue != nil
        }
        .alert("Can't Mark Photo", isPresented: $showMarkError) {
            Button("OK") { queue.clearError() }
        } message: {
            Text(queue.lastError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func prev() { if currentIndex > 0 { currentIndex -= 1 } }
    private func next() { if currentIndex < localPhotos.count - 1 { currentIndex += 1 } }

    /// Bring the current photo into focus inside the macOS Photos app.
    ///
    /// The Photos AppleScript `media item id` is NOT reliably the bare UUID:
    /// depending on macOS version it is the full PHAsset localIdentifier
    /// ("UUID/L0/001") or just the UUID. The previous code always stripped to
    /// the UUID, so on systems that key on the full identifier `spotlight` found
    /// no match and silently revealed the wrong (last-viewed) photo. We now try
    /// the full identifier first and fall back to the UUID inside the script, so
    /// whichever form Photos expects, the correct photo is revealed. If both
    /// fail we just activate Photos.
    private func openInPhotos() {
        guard let fullId = current.localIdentifier, !fullId.isEmpty else {
            activatePhotos()
            return
        }
        let uuid = fullId.components(separatedBy: "/").first ?? fullId
        let escapedFull = fullId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedUUID = uuid.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Photos"
            activate
            try
                spotlight (media item id "\(escapedFull)")
            on error
                spotlight (media item id "\(escapedUUID)")
            end try
        end tell
        """

        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&errorDict)
        }
        if errorDict != nil {
            activatePhotos()
        }
    }

    private func activatePhotos() {
        if let photosURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.open(photosURL)
        }
    }

    /// Marks (or unmarks) the current photo for batch deletion. Marking is
    /// reversible and never deletes here — the actual removal happens when the
    /// user commits from the app-wide bar. After marking, advance to the next
    /// photo so rapid review flows naturally; unmarking stays put.
    private func toggleMark() {
        if queue.isMarked(current.uuid) {
            queue.unmark(current.uuid)
        } else if queue.mark(current) {
            if currentIndex < localPhotos.count - 1 { next() }
        }
    }

    /// Backspace handler: pure toggle of the current photo's marked state, with
    /// no auto-advance (unlike the Mark button, which advances for fast review).
    private func toggleMarkInPlace() {
        if queue.isMarked(current.uuid) {
            queue.unmark(current.uuid)
        } else {
            queue.mark(current)
        }
    }

    private func arrowButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.white.opacity(0.75))
                .shadow(color: .black.opacity(0.5), radius: 4)
        }
        .buttonStyle(.plain)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private func formattedDate(_ ts: Double) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: ts))
    }
}

struct LightboxMediaView: View {
    let photo: PhotoMeta

    private var isVideo: Bool {
        ["mov", "mp4", "m4v"].contains((photo.filename as NSString).pathExtension.lowercased())
    }

    var body: some View {
        if isVideo {
            LightboxVideoView(photo: photo)
        } else {
            // The image is letterboxed inside a full-size frame, so its
            // transparent margins would otherwise swallow "tap outside to
            // dismiss". Disable hit testing so those taps fall through to the
            // backdrop's dismiss gesture (a still image needs no interaction).
            LightboxImageView(photo: photo)
                .allowsHitTesting(false)
        }
    }
}

struct LightboxImageView: View {
    let photo: PhotoMeta
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear { load() }
        .onDisappear { if let id = requestID { PHImageManager.default().cancelImageRequest(id) } }
    }

    private func load() {
        let identifier = photo.localIdentifier ?? "\(photo.uuid)/L0/001"
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 2400, height: 2400),
            contentMode: .aspectFit,
            options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async { self.image = img }
        }
    }
}

struct LightboxVideoView: View {
    let photo: PhotoMeta
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 52)).foregroundStyle(.white.opacity(0.35))
                    Text("Video not available locally")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .onAppear {
            guard let path = photo.filePath else { return }
            let p = AVPlayer(url: URL(fileURLWithPath: path))
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}


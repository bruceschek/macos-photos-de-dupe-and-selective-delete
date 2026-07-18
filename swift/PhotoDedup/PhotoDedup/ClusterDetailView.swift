import SwiftUI
import Photos
import AppKit
import AVFoundation
import AVKit

struct ClusterDetailView: View {
    let clusterId: Int

    @State private var detail: ClusterDetail?
    @State private var isLoading = true
    @State private var selectedUUIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var deleteError: String?
    @State private var showLightbox = false
    @State private var lightboxIndex = 0

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
        .alert("Delete Error", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showLightbox) {
            if let photos = detail?.photos {
                LightboxView(
                    photos: photos,
                    initialIndex: lightboxIndex,
                    onDelete: { uuid in
                        detail?.photos.removeAll { $0.uuid == uuid }
                        selectedUUIDs.remove(uuid)
                    }
                )
                .frame(minWidth: 760, minHeight: 560)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: ClusterDetail) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(detail.photos) { photo in
                    PhotoCard(
                        photo: photo,
                        isSelected: selectedUUIDs.contains(photo.uuid),
                        onToggleSelect: { toggleSelection(photo.uuid) },
                        onDelete: { await deleteSingle(photo) },
                        onOpen: {
                            lightboxIndex = detail.photos.firstIndex(where: { $0.uuid == photo.uuid }) ?? 0
                            showLightbox = true
                        }
                    )
                }
            }
            .padding()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Move \(selectedUUIDs.count) to Trash", systemImage: "trash")
            }
            .disabled(selectedUUIDs.isEmpty)
            .confirmationDialog(
                "Move \(selectedUUIDs.count) photo(s) to trash?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await deleteSelected() }
                }
            } message: {
                Text("Photos will remain in the Recently Deleted album for 30 days before permanent deletion.")
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            if !selectedUUIDs.isEmpty {
                Button("Deselect All") { selectedUUIDs.removeAll() }
            }
        }
    }

    private func toggleSelection(_ uuid: String) {
        if selectedUUIDs.contains(uuid) {
            selectedUUIDs.remove(uuid)
        } else {
            selectedUUIDs.insert(uuid)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        detail = nil
        selectedUUIDs = []
        do {
            let loaded = try await CurrentBackend.shared.cluster(id: clusterId)
            detail = loaded
            isLoading = false
        } catch is CancellationError {
            // user navigated to another cluster; new task owns loading state
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteSelected() async {
        guard let detail else { return }
        let identifiers = detail.photos
            .filter { selectedUUIDs.contains($0.uuid) }
            .compactMap(\.localIdentifier)

        guard identifiers.count == selectedUUIDs.count else {
            deleteError = "Some selected assets are missing full PhotoKit identifiers. Run a new scan before deleting."
            return
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard assets.count == identifiers.count else {
            deleteError = "Some selected assets could not be found in Photos. Nothing was moved to trash."
            return
        }
        await performDelete(assets)
    }

    @MainActor
    private func deleteSingle(_ photo: PhotoMeta) async {
        guard let identifier = photo.localIdentifier else {
            deleteError = "Missing PhotoKit identifier. Run a new scan before deleting."
            return
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else {
            deleteError = "Asset not found in Photos library."
            return
        }
        await performDelete(assets)
    }

    @MainActor
    private func performDelete(_ assets: [PHAsset]) async {
        // performChanges:completionHandler: crashes with _dispatch_assert_queue_fail when
        // the Photos daemon returns com.apple.accounts Code=7 during changes execution —
        // the crash occurs before our completion handler is even called, so dispatching
        // to main in the handler can't save us. performChangesAndWait throws an NSError
        // in the same condition instead of crashing. Run it on a background thread so
        // it doesn't block the main thread while Photos commits.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try PHPhotoLibrary.shared().performChangesAndWait {
                            PHAssetChangeRequest.deleteAssets(assets as NSArray)
                        }
                        DispatchQueue.main.async { cont.resume() }
                    } catch {
                        DispatchQueue.main.async { cont.resume(throwing: error) }
                    }
                }
            }
            selectedUUIDs.removeAll()
            await load()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

struct PhotoCard: View {
    let photo: PhotoMeta
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onDelete: () async -> Void
    let onOpen: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail — tap to open lightbox
            PHAssetThumbnailView(photo: photo)
                .frame(height: 180)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }

            VStack(alignment: .leading, spacing: 4) {
                // Checkbox + filename — toggles selection
                Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggleSelect() })) {
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

                Button(role: .destructive, action: { showDeleteConfirm = true }) {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .padding(.top, 2)
                .confirmationDialog("Move to Recently Deleted?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { Task { await onDelete() } }
                } message: {
                    Text("The photo stays in Recently Deleted for 30 days.")
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
    /// Called with the deleted photo's UUID so the parent grid can remove the row.
    let onDelete: (String) -> Void

    @State private var localPhotos: [PhotoMeta]
    @State private var currentIndex: Int
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(photos: [PhotoMeta], initialIndex: Int, onDelete: @escaping (String) -> Void) {
        self.onDelete = onDelete
        _localPhotos = State(initialValue: photos)
        _currentIndex = State(initialValue: initialIndex)
    }

    private var current: PhotoMeta { localPhotos[currentIndex] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                                Text(formattedDate(ts)).font(.caption).foregroundStyle(.white.opacity(0.65))
                            }
                            if let w = current.width, let h = current.height {
                                Text("\(w)×\(h)").font(.caption).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                    Spacer()
                    Text("\(currentIndex + 1) / \(localPhotos.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                    Button(action: openInPhotos) {
                        Label("Open in Photos", systemImage: "arrow.up.forward.app")
                            .padding(.horizontal, 4)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal this photo in the Photos app")
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
        .onKeyPress(.escape)     { dismiss(); return .handled }
        .confirmationDialog(
            "Move \(current.filename) to Recently Deleted?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            actions: {
                Button("Move to Trash", role: .destructive) {
                    Task { await performLightboxDelete() }
                }
            },
            message: {
                Text("The photo stays in Recently Deleted for 30 days before permanent removal.")
            }
        )
        .alert("Delete Error", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
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
    /// Strategy: run a brief AppleScript that tells Photos to `spotlight` the
    /// item using its internal UUID (the leading segment of the PHAsset
    /// localIdentifier before the first `/`).  If AppleScript fails for any
    /// reason — Photos not installed, sandboxing, older OS — we fall back to
    /// simply activating Photos so the user at least lands in the right app.
    private func openInPhotos() {
        // PHAsset localIdentifier looks like "UUID/L0/001". Photos AppleScript
        // uses just the UUID portion as the media item id.
        let photosId = current.localIdentifier?
            .components(separatedBy: "/").first ?? ""

        let script: String
        if photosId.isEmpty {
            script = #"tell application "Photos" to activate"#
        } else {
            script = """
            tell application "Photos"
                activate
                spotlight (media item id "\(photosId)")
            end tell
            """
        }

        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&errorDict)
        }
        if errorDict != nil {
            // AppleScript failed (sandboxing, Photos absent, etc.) — open Photos directly.
            if let photosURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                NSWorkspace.shared.open(photosURL)
            }
        }
    }

    @MainActor
    private func performLightboxDelete() async {
        let photo = localPhotos[currentIndex]
        guard let identifier = photo.localIdentifier else {
            deleteError = "Missing PhotoKit identifier. Run a new scan before deleting."
            return
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else {
            deleteError = "Asset not found in Photos library."
            return
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try PHPhotoLibrary.shared().performChangesAndWait {
                            PHAssetChangeRequest.deleteAssets(assets as NSArray)
                        }
                        DispatchQueue.main.async { cont.resume() }
                    } catch {
                        DispatchQueue.main.async { cont.resume(throwing: error) }
                    }
                }
            }

            let deletedUUID = photo.uuid
            onDelete(deletedUUID)                   // remove from parent grid
            localPhotos.remove(at: currentIndex)    // remove from lightbox list

            if localPhotos.isEmpty {
                dismiss()
            } else if currentIndex >= localPhotos.count {
                currentIndex = localPhotos.count - 1 // was last item; step back
            }
        } catch {
            deleteError = error.localizedDescription
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
        if isVideo { LightboxVideoView(photo: photo) }
        else        { LightboxImageView(photo: photo) }
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


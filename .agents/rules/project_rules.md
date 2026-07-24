# PhotoDedup Workspace Rules & Coding Guidelines

Welcome to the `PhotoDedup` macOS application workspace. These rules define the architecture, data models, coding styles, database schemas, and build procedures for this project. Use them to ensure code updates align with the design principles of the project.

---

## 1. System Architecture Overview

`PhotoDedup` is a SwiftUI-based macOS app that performs perceptual hashing and classification on macOS Photo Library assets, clusters similar photos, and lets users delete duplicates safely.

### Component Map
*   **App Entry Point**: [PhotoDedupApp.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/PhotoDedupApp.swift)
*   **UI Views**:
    *   [ClusterListView.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/ClusterListView.swift): Sidebar navigation listing all duplicate groups (clusters).
    *   [ClusterDetailView.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/ClusterDetailView.swift): Grid detailing members of a selected cluster and action flows for deletion.
*   **Backend & Pipelines**:
    *   [LocalBackend.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/LocalBackend.swift): Coordinates ingestion, multi-worker hashing, live clustering updates, and scene captioning.
    *   [PhotoLibraryBridge.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/PhotoLibraryBridge.swift): Handles photo authorization and metadata fetch results from `PHPhotoLibrary` (`PhotoKit`).
*   **Algorithmic Engines**:
    *   [Clusterer.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/Clusterer.swift): Defines clustering logic (e.g. Burst, Exact filename, Raw+Jpeg, Live photo, and Perceptual similarity).
    *   [PHash.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/PHash.swift): Implements a 2D discrete cosine transform (DCT-II) algorithm producing 64-bit hex-encoded hashes for 8 dihedral orientations.
    *   [AssetHasher.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/AssetHasher.swift): Generates perceptual hashes using `PhotoKit` thumbnail generation.
    *   [ImageClassifier.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/ImageClassifier.swift): Local Vision classifier extracting 2-3 word labels for clusters via on-device `VNClassifyImageRequest`.
*   **Data Tier**:
    *   [PhotoStore.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/PhotoStore.swift): Manages a local SQLite database using **GRDB.swift** (WAL mode enabled for concurrent reader isolation).
    *   [Models.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/Models.swift): Contains structures for data serialization and API mapping.

---

## 2. Coding Guidelines & Best Practices

### A. Concurrency and Thread Safety
*   **Database Isolation**: State mutation of database data must be actor-isolated. Use [PhotoStore](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/PhotoStore.swift) to write updates via `store.write` and read via `store.read`.
*   **Backend Isolation**: Heavy processing tasks (e.g., photo hashing, caption generation, indexing) must run on background task groups within the [LocalBackend](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/LocalBackend.swift) actor.
*   **Nonisolated Helpers**: CPU-heavy calculations (e.g., pixel math, DCT-II, Vision image analysis) should be `nonisolated static` methods to run on the global concurrent executor and keep actors responsive.

### B. UI & Design Styling
*   **Typography Scale**: Never hardcode standard system font weights/styles directly in SwiftUI views. Use the predefined styling rules from [Typography.swift](file:///Users/bruceschechter/dev/swift/012-photo-app-de-dupe-and-deletion/swift/PhotoDedup/PhotoDedup/Typography.swift):
    *   `AppFont.small`: Subheadline (for secondary metadata)
    *   `AppFont.base`: Callout (for primary UI text)
    *   `AppFont.label`: Body (for prominent labels)
*   **State Observation**: Use Swift's native `@Observable` macro (for SwiftUI 5+) for bridge structures and view models.

### C. Database Schemas & Swappability
The local database schema at `~/Library/Application Support/PhotoDedup/photos.db` contains four primary tables matching the structure of the sister Python ML implementation:

*   **`photos`**
    *   `uuid` (TEXT PRIMARY KEY)
    *   `local_identifier` (TEXT)
    *   `filename` (TEXT NOT NULL)
    *   `original_filename` (TEXT)
    *   `date_taken` (REAL)
    *   `burst_uuid` (TEXT)
    *   `is_raw` (INTEGER)
    *   `is_live` (INTEGER)
    *   `width` / `height` (INTEGER)
    *   `is_local` (INTEGER)
    *   `file_path` (TEXT)
    *   `media_type` (TEXT)
    *   `duration` (REAL)
    *   `phash` (TEXT)
    *   `phash_variants` (TEXT) - Alternate hashes for rotations/mirrors/video frames
    *   `scanned_at` (REAL)
*   **`clusters`**
    *   `id` (INTEGER PRIMARY KEY AUTOINCREMENT)
    *   `kind` (TEXT NOT NULL) - e.g., `"burst"`, `"exact_name"`, `"raw_jpeg"`, `"live_photo"`, `"phash"`
    *   `confidence` (REAL)
    *   `created_at` (REAL)
    *   `caption` (TEXT) - Vision classification labels
*   **`cluster_members`**
    *   `cluster_id` (INTEGER REFERENCES clusters(id) ON DELETE CASCADE)
    *   `photo_uuid` (TEXT REFERENCES photos(uuid) ON DELETE CASCADE)
*   **`scan_state`**
    *   `key` (TEXT PRIMARY KEY)
    *   `value` (TEXT)

> [!WARNING]
> Keep database column alterations inside `PhotoStore.swift` migrations, making sure tables remain swappable with Python models. Do not drop tables; append schema updates to new migration versions.

---

## 3. Build & Compilation Procedures

To build the project locally, run:
```bash
xcodebuild -project swift/PhotoDedup/PhotoDedup.xcodeproj -scheme PhotoDedup -configuration Debug -destination "platform=macOS" build
```

> [!IMPORTANT]
> The build command must be executed with **`BypassSandbox: true`** enabled. The Swift Package Manager cache and derived data paths are located outside the standard agent workspace (e.g. `/var/folders` and `~/Library`), requiring full system permission to fetch GRDB.swift and compile Xcode assets.

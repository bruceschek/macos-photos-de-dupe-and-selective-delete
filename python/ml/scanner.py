"""
Read-only photo analysis pipeline.
Swift provides all metadata + file paths; this module only reads image
files for perceptual hashing. It NEVER accesses the Photos library
database and NEVER deletes or modifies photos.
"""

import io
import shutil
import subprocess
import tempfile
import time
import logging
import threading
from pathlib import Path

import imagehash
from PIL import Image

from db import get_conn, init_db

# ffmpeg is used to extract a representative frame from each video for pHash.
# Graceful degradation: if ffmpeg isn't on PATH, video clustering falls back to
# metadata-only mode (tighter thresholds still reduce false positives).
_FFMPEG = shutil.which("ffmpeg")

logger = logging.getLogger(__name__)

PHASH_THRESHOLD = 4
_PHASH_MIN_BITS = 4
_PHASH_MAX_BITS = 60

_lock = threading.Lock()
_state: dict = {
    "state": "idle",        # idle | ingesting | hashing | done | error
    "total_photos": 0,
    "ingested": 0,
    "scanned": 0,
    "skipped_cloud": 0,
    "clusters_found": 0,
    "error": None,
    "scan_start_time": None,
}


def get_scan_state() -> dict:
    return dict(_state)


def _upd(**kw) -> None:
    _state.update(kw)


# ---------------------------------------------------------------------------
# Ingest — called by Swift in batches; stores metadata into SQLite
# ---------------------------------------------------------------------------

def begin_scan() -> None:
    """Clear previous results and prepare for a fresh ingest from Swift."""
    init_db()
    conn = get_conn()
    conn.execute("DELETE FROM cluster_members")
    conn.execute("DELETE FROM clusters")
    conn.execute("DELETE FROM photos")
    conn.commit()
    _upd(state="ingesting", total_photos=0, ingested=0, scanned=0,
         skipped_cloud=0, clusters_found=0, error=None, scan_start_time=time.time())
    logger.info("Scan reset — ready for ingestion")


def ingest_batch(records: list[dict]) -> None:
    """Store a batch of photo records received from Swift."""
    conn = get_conn()
    now = time.time()
    for r in records:
        conn.execute("""
            INSERT OR REPLACE INTO photos
              (uuid, local_identifier, filename, original_filename, date_taken, burst_uuid,
               is_raw, is_live, width, height, is_local, file_path,
               media_type, duration, scanned_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (
            r["uuid"],
            r.get("local_identifier"),
            r.get("filename", r["uuid"]),
            r.get("original_filename"),
            r.get("date_taken"),
            r.get("burst_uuid"),
            int(r.get("is_raw", False)),
            int(r.get("is_live", False)),
            r.get("width"),
            r.get("height"),
            int(r.get("is_local", False)),
            r.get("file_path"),
            r.get("media_type", "image"),
            r.get("duration"),
            now,
        ))
    conn.commit()
    ingested = conn.execute("SELECT COUNT(*) FROM photos").fetchone()[0]
    _upd(ingested=ingested, total_photos=ingested)
    logger.info("Ingested batch; total so far: %d", ingested)


# ---------------------------------------------------------------------------
# Hashing — background job started after ingestion is complete
# ---------------------------------------------------------------------------

def start_hashing() -> bool:
    """Start background hashing. Returns False if already running."""
    if not _lock.acquire(blocking=False):
        return False
    t = threading.Thread(target=_run_hashing, daemon=True)
    t.start()
    return True


def _run_hashing() -> None:
    try:
        _upd(state="hashing", scanned=0)
        _hash_photos()
        _upd(state="clustering")
        _build_clusters()
        _upd(state="done")
        logger.info("Scan complete")
    except Exception as exc:
        logger.exception("Hashing failed")
        _upd(state="error", error=str(exc))
    finally:
        _lock.release()


def _hash_photos() -> None:
    conn = get_conn()
    image_rows = conn.execute(
        "SELECT uuid, file_path FROM photos WHERE file_path IS NOT NULL AND is_local = 1 AND media_type = 'image'"
    ).fetchall()
    # Extract a representative frame pHash for local videos only when ffmpeg is present.
    # This powers the visual-similarity check in _cluster_videos.
    video_rows = conn.execute(
        "SELECT uuid, file_path FROM photos WHERE file_path IS NOT NULL AND is_local = 1 AND media_type = 'video'"
    ).fetchall() if _FFMPEG else []

    total = conn.execute("SELECT COUNT(*) FROM photos").fetchone()[0]
    skipped = conn.execute(
        "SELECT COUNT(*) FROM photos WHERE is_local = 0 OR file_path IS NULL"
    ).fetchone()[0]
    _upd(total_photos=total, skipped_cloud=skipped)

    scanned = 0
    for row in image_rows:
        phash = _compute_phash(row["file_path"])
        if phash:
            conn.execute("UPDATE photos SET phash=? WHERE uuid=?",
                         (str(phash), row["uuid"]))
        scanned += 1
        _upd(scanned=scanned)
        if scanned % 200 == 0:
            conn.commit()
            logger.info("Hashed %d / %d images; file: %s", scanned, len(image_rows), row["file_path"])

    if video_rows:
        logger.info("Extracting frame pHash for %d local videos via ffmpeg", len(video_rows))
    for row in video_rows:
        phash = _compute_video_phash(row["file_path"])
        if phash:
            conn.execute("UPDATE photos SET phash=? WHERE uuid=?",
                         (str(phash), row["uuid"]))
        scanned += 1
        _upd(scanned=scanned)
        if scanned % 50 == 0:
            conn.commit()
            logger.info("Video frame pHash %d / %d total; file: %s", scanned, total, row["file_path"])

    conn.commit()


def _compute_phash(path: str) -> "imagehash.ImageHash | None":
    try:
        if not Path(path).exists():
            return None
        with Image.open(path) as img:
            return imagehash.phash(img.convert("RGB"))
    except Exception as exc:
        logger.debug("pHash failed for %s: %s", path, exc)
        return None


def _compute_video_phash(path: str) -> "imagehash.ImageHash | None":
    """Extract the first decodable frame from a video via ffmpeg and return its pHash.

    Returns None if ffmpeg is unavailable, the file is missing, or extraction fails.
    The frame is scaled to 128×128 before hashing to normalise resolution differences.
    """
    if not _FFMPEG or not Path(path).exists():
        return None
    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            tmp_path = tmp.name
        result = subprocess.run(
            [
                _FFMPEG, "-y",
                "-i", path,
                "-frames:v", "1",
                "-vf", "scale=128:128:force_original_aspect_ratio=increase",
                "-q:v", "2",
                tmp_path,
            ],
            capture_output=True,
            timeout=20,
        )
        if result.returncode != 0:
            logger.debug("ffmpeg frame extraction failed for %s (rc=%d)", path, result.returncode)
            return None
        with Image.open(tmp_path) as img:
            return imagehash.phash(img.convert("RGB"))
    except Exception as exc:
        logger.debug("Video pHash failed for %s: %s", path, exc)
        return None
    finally:
        if tmp_path:
            try:
                Path(tmp_path).unlink(missing_ok=True)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Clustering
# ---------------------------------------------------------------------------

def _build_clusters() -> None:
    conn = get_conn()
    now = time.time()
    conn.execute("DELETE FROM cluster_members")
    conn.execute("DELETE FROM clusters")
    conn.commit()

    _cluster_bursts(conn, now)
    _cluster_raw_jpeg(conn, now)
    _cluster_live_photos(conn, now)
    _cluster_phash(conn, now)
    _cluster_videos(conn, now)
    conn.commit()

    count = conn.execute("SELECT COUNT(*) FROM clusters").fetchone()[0]
    _upd(clusters_found=count)


def _cluster_bursts(conn, now: float) -> None:
    rows = conn.execute("""
        SELECT burst_uuid, GROUP_CONCAT(uuid) as uuids
        FROM photos WHERE burst_uuid IS NOT NULL
        GROUP BY burst_uuid HAVING COUNT(*) > 1
    """).fetchall()
    for row in rows:
        uuids = row["uuids"].split(",")
        cid = conn.execute(
            "INSERT INTO clusters (kind, confidence, created_at) VALUES ('burst', 1.0, ?)", (now,)
        ).lastrowid
        conn.executemany("INSERT INTO cluster_members VALUES (?,?)", [(cid, u) for u in uuids])


_GENERIC_STEMS = frozenset({"fullsizerender", "img_e"})
# RAW+JPEG from the same camera shot are captured simultaneously. Allow 120s for
# minor clock drift; anything farther apart is a different shot with a recycled name.
_RAW_JPEG_MAX_GAP_S = 120.0

def _cluster_raw_jpeg(conn, now: float) -> None:
    rows = conn.execute("""
        SELECT uuid, original_filename, is_raw, date_taken FROM photos
        WHERE is_raw = 1
           OR lower(original_filename) LIKE '%.jpg'
           OR lower(original_filename) LIKE '%.jpeg'
    """).fetchall()

    stems: dict[str, list] = {}
    for row in rows:
        if not row["original_filename"]:
            continue
        stem = Path(row["original_filename"]).stem.lower()
        if stem in _GENERIC_STEMS:
            continue
        stems.setdefault(stem, []).append({
            "uuid": row["uuid"],
            "is_raw": bool(row["is_raw"]),
            "date_taken": row["date_taken"] or 0.0,
        })

    for entries in stems.values():
        if len(entries) < 2:
            continue

        # Sub-group by capture time — sequential camera counters like IMG_0544 reset
        # across trips, so the same stem can appear for completely unrelated photos.
        entries.sort(key=lambda e: e["date_taken"])
        time_groups: list[list[dict]] = []
        for entry in entries:
            placed = False
            for group in time_groups:
                if abs(entry["date_taken"] - group[0]["date_taken"]) <= _RAW_JPEG_MAX_GAP_S:
                    group.append(entry)
                    placed = True
                    break
            if not placed:
                time_groups.append([entry])

        for group in time_groups:
            if len(group) < 2:
                continue
            has_raw = any(e["is_raw"] for e in group)
            has_jpeg = any(not e["is_raw"] for e in group)
            if not (has_raw and has_jpeg):
                continue
            uuids = [e["uuid"] for e in group]
            cid = conn.execute(
                "INSERT INTO clusters (kind, confidence, created_at) VALUES ('raw_jpeg', 1.0, ?)", (now,)
            ).lastrowid
            conn.executemany("INSERT INTO cluster_members VALUES (?,?)", [(cid, u) for u in uuids])


def _cluster_live_photos(conn, now: float) -> None:
    # Only cluster by burst_uuid — filename-stem matching is too broad because iOS
    # names edited photos "FullSizeRender", causing unrelated photos to collapse into
    # one giant cluster.
    rows = conn.execute(
        "SELECT uuid, burst_uuid FROM photos WHERE is_live = 1 AND burst_uuid IS NOT NULL"
    ).fetchall()
    groups: dict[str, list] = {}
    for row in rows:
        groups.setdefault(row["burst_uuid"], []).append(row["uuid"])
    for uuids in groups.values():
        if len(uuids) > 1:
            cid = conn.execute(
                "INSERT INTO clusters (kind, confidence, created_at) VALUES ('live', 1.0, ?)", (now,)
            ).lastrowid
            conn.executemany("INSERT INTO cluster_members VALUES (?,?)", [(cid, u) for u in uuids])


# Real duplicate videos are typically recorded within seconds of each other
# (burst, app export, trim copy).  Apps that export processed clips reuse the
# original filename but produce files minutes or hours apart — tightening this
# window eliminates most "same name, different content" false positives.
_VIDEO_MAX_GAP_S = 120.0      # tightened from 3600 s
_VIDEO_DUR_TOL_S = 1.0        # tightened from 2 s
_VIDEO_PHASH_THRESHOLD = 10   # Hamming distance for frame pHashes (looser than
                               # photo threshold — frame extraction is noisier)
# Max ratio between two aspect ratios before we treat clips as different orientations.
# 1.20 means a 5:4 vs 4:3 would still pass; landscape vs portrait fails immediately.
_VIDEO_AR_MAX_RATIO = 1.20


def _cluster_videos(conn, now: float) -> None:
    """Cluster videos using a four-level funnel:

    1. Same filename stem
    2. Capture-time proximity (≤ _VIDEO_MAX_GAP_S)
    3. Duration proximity (≤ _VIDEO_DUR_TOL_S) + aspect-ratio sanity check
    4. Frame pHash similarity (if available via ffmpeg) — hard visual veto
    """
    rows = conn.execute("""
        SELECT uuid, original_filename, duration, date_taken, phash, width, height
        FROM photos WHERE media_type = 'video'
    """).fetchall()

    stems: dict[str, list] = {}
    for row in rows:
        stem = Path(row["original_filename"]).stem.lower() if row["original_filename"] else None
        if stem:
            stems.setdefault(stem, []).append({
                "uuid":       row["uuid"],
                "duration":   row["duration"] or 0.0,
                "date_taken": row["date_taken"] or 0.0,
                "phash":      row["phash"],
                "width":      row["width"] or 0,
                "height":     row["height"] or 0,
            })

    for entries in stems.values():
        if len(entries) < 2:
            continue

        # Level 1 → 2: capture-time grouping
        entries.sort(key=lambda e: e["date_taken"])
        time_groups: list[list[dict]] = []
        for entry in entries:
            placed = False
            for tg in time_groups:
                if abs(entry["date_taken"] - tg[0]["date_taken"]) <= _VIDEO_MAX_GAP_S:
                    tg.append(entry)
                    placed = True
                    break
            if not placed:
                time_groups.append([entry])

        for tg in time_groups:
            if len(tg) < 2:
                continue

            # Level 3a: duration grouping
            dur_groups: list[list[dict]] = []
            for entry in tg:
                placed = False
                for dg in dur_groups:
                    if abs(dg[0]["duration"] - entry["duration"]) <= _VIDEO_DUR_TOL_S:
                        dg.append(entry)
                        placed = True
                        break
                if not placed:
                    dur_groups.append([entry])

            for dg in dur_groups:
                if len(dg) < 2:
                    continue

                # Level 3b: aspect-ratio sanity check.
                # Portrait vs landscape, or significantly different crops, are different clips.
                dims = [(e["width"], e["height"]) for e in dg if e["width"] > 0 and e["height"] > 0]
                if len(dims) == len(dg):
                    ratios = [w / h for w, h in dims]
                    if min(ratios) > 0 and max(ratios) / min(ratios) > _VIDEO_AR_MAX_RATIO:
                        logger.debug(
                            "Skipping video cluster — aspect-ratio mismatch %s for %s",
                            ratios, [e["uuid"] for e in dg],
                        )
                        continue

                # Level 4: frame pHash veto.
                # When ffmpeg produced hashes for every video in this group, ALL pairs
                # must be visually similar.  A single mismatch disqualifies the whole group.
                hashes = [(e["uuid"], e["phash"]) for e in dg]
                if all(h is not None for _, h in hashes):
                    phash_ints = [(u, int(h, 16)) for u, h in hashes]
                    if not _all_pairs_within(phash_ints, _VIDEO_PHASH_THRESHOLD):
                        logger.debug(
                            "Skipping video cluster — frame pHash mismatch (visually different) for %s",
                            [u for u, _ in phash_ints],
                        )
                        continue

                uuids = [e["uuid"] for e in dg]
                cid = conn.execute(
                    "INSERT INTO clusters (kind, confidence, created_at) VALUES ('video', 1.0, ?)", (now,)
                ).lastrowid
                conn.executemany("INSERT INTO cluster_members VALUES (?,?)", [(cid, u) for u in uuids])


def _all_pairs_within(phash_ints: list[tuple[str, int]], threshold: int) -> bool:
    """Return True iff every pair of pHash values is within the Hamming threshold."""
    for i in range(len(phash_ints)):
        for j in range(i + 1, len(phash_ints)):
            if _hamming_distance(phash_ints[i][1], phash_ints[j][1]) > threshold:
                return False
    return True


def _cluster_phash(conn, now: float) -> None:
    rows = conn.execute(
        "SELECT uuid, phash, original_filename FROM photos WHERE phash IS NOT NULL"
    ).fetchall()
    if not rows:
        return
    hashes: list[tuple[str, int]] = []
    skipped = 0
    for row in rows:
        hash_value = int(row["phash"], 16)
        bit_count = hash_value.bit_count()
        if bit_count <= _PHASH_MIN_BITS or bit_count >= _PHASH_MAX_BITS:
            skipped += 1
            continue
        hashes.append((row["uuid"], hash_value))
    if skipped:
        logger.info("Skipped %d low-signal pHash candidates", skipped)
    if not hashes:
        return
    _upd(total_photos=len(hashes), scanned=0)

    parent = {uuid: uuid for uuid, _ in hashes}

    def find(uuid: str) -> str:
        while parent[uuid] != uuid:
            parent[uuid] = parent[parent[uuid]]
            uuid = parent[uuid]
        return uuid

    def union(uuid_a: str, uuid_b: str) -> None:
        root_a = find(uuid_a)
        root_b = find(uuid_b)
        if root_a != root_b:
            parent[root_b] = root_a

    tree = _BKTree()
    for index, (uuid, hash_value) in enumerate(hashes, start=1):
        for neighbor_uuid in tree.find(hash_value, PHASH_THRESHOLD):
            union(uuid, neighbor_uuid)
        tree.add(hash_value, uuid)
        if index % 1000 == 0:
            _upd(scanned=index)
            logger.info("Clustered pHash candidates %d / %d", index, len(hashes))
    _upd(scanned=len(hashes))

    groups: dict[str, list[str]] = {}
    for uuid, _ in hashes:
        groups.setdefault(find(uuid), []).append(uuid)

    for group in groups.values():
        if len(group) > 1:
            confidence = max(0.0, 1.0 - PHASH_THRESHOLD / 64.0)
            cid = conn.execute(
                "INSERT INTO clusters (kind, confidence, created_at) VALUES ('phash', ?, ?)",
                (confidence, now),
            ).lastrowid
            conn.executemany("INSERT INTO cluster_members VALUES (?,?)", [(cid, u) for u in group])


def _hamming_distance(a: int, b: int) -> int:
    return (a ^ b).bit_count()


class _BKTree:
    """Metric tree for pHash Hamming-distance neighbor lookups."""

    def __init__(self) -> None:
        self.root: tuple[int, list[str], dict[int, object]] | None = None

    def add(self, hash_value: int, uuid: str) -> None:
        if self.root is None:
            self.root = (hash_value, [uuid], {})
            return

        node = self.root
        while True:
            node_hash, node_uuids, children = node
            distance = _hamming_distance(hash_value, node_hash)
            if distance == 0:
                node_uuids.append(uuid)
                return
            child = children.get(distance)
            if child is None:
                children[distance] = (hash_value, [uuid], {})
                return
            node = child

    def find(self, hash_value: int, threshold: int) -> list[str]:
        if self.root is None:
            return []

        matches: list[str] = []
        stack = [self.root]
        while stack:
            node_hash, node_uuids, children = stack.pop()
            distance = _hamming_distance(hash_value, node_hash)
            if distance <= threshold:
                matches.extend(node_uuids)

            low = distance - threshold
            high = distance + threshold
            for edge_distance, child in children.items():
                if low <= edge_distance <= high:
                    stack.append(child)
        return matches

import sqlite3
import threading
from pathlib import Path

DB_PATH = Path(__file__).parent / "photos.db"

_local = threading.local()


def get_conn() -> sqlite3.Connection:
    if not hasattr(_local, "conn"):
        _local.conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        _local.conn.row_factory = sqlite3.Row
        _local.conn.execute("PRAGMA journal_mode=WAL")
        _local.conn.execute("PRAGMA foreign_keys=ON")
    return _local.conn


def init_db() -> None:
    conn = get_conn()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS photos (
            uuid        TEXT PRIMARY KEY,
            local_identifier TEXT,
            filename    TEXT NOT NULL,
            original_filename TEXT,
            date_taken  REAL,
            burst_uuid  TEXT,
            is_raw      INTEGER NOT NULL DEFAULT 0,
            is_live     INTEGER NOT NULL DEFAULT 0,
            width       INTEGER,
            height      INTEGER,
            is_local    INTEGER NOT NULL DEFAULT 1,
            file_path   TEXT,
            media_type  TEXT NOT NULL DEFAULT 'image',
            duration    REAL,
            phash       TEXT,
            scanned_at  REAL
        );

        CREATE INDEX IF NOT EXISTS idx_photos_phash      ON photos(phash);
        CREATE INDEX IF NOT EXISTS idx_photos_burst_uuid ON photos(burst_uuid);
        CREATE INDEX IF NOT EXISTS idx_photos_filename   ON photos(original_filename);

        CREATE TABLE IF NOT EXISTS clusters (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            kind        TEXT NOT NULL,  -- 'phash' | 'burst' | 'raw_jpeg' | 'live'
            confidence  REAL NOT NULL DEFAULT 1.0,
            created_at  REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS cluster_members (
            cluster_id  INTEGER NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
            photo_uuid  TEXT    NOT NULL REFERENCES photos(uuid) ON DELETE CASCADE,
            PRIMARY KEY (cluster_id, photo_uuid)
        );

        CREATE INDEX IF NOT EXISTS idx_cm_cluster ON cluster_members(cluster_id);
        CREATE INDEX IF NOT EXISTS idx_cm_photo   ON cluster_members(photo_uuid);

        CREATE TABLE IF NOT EXISTS scan_state (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
    """)
    conn.commit()
    for migration in [
        "ALTER TABLE photos ADD COLUMN local_identifier TEXT",
        "ALTER TABLE photos ADD COLUMN file_path TEXT",
        "ALTER TABLE photos ADD COLUMN media_type TEXT NOT NULL DEFAULT 'image'",
        "ALTER TABLE photos ADD COLUMN duration REAL",
    ]:
        try:
            conn.execute(migration)
            conn.commit()
        except Exception:
            pass

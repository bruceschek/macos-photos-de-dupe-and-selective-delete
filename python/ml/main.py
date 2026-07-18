import io
import faulthandler
import logging
import time
from pathlib import Path
from typing import Any

from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel

import db as database
import scanner
from models import ClusterDetail, ClusterSummary, PhotoMeta, ScanStatus

logging.basicConfig(level=logging.INFO)
faulthandler.enable()


@asynccontextmanager
async def lifespan(app: FastAPI):
    database.init_db()
    yield


app = FastAPI(title="Photo Dedup API", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Scan lifecycle  (Swift drives ingestion; Python drives hashing)
# ---------------------------------------------------------------------------

@app.post("/scan/begin", status_code=202)
def scan_begin():
    """Reset DB and prepare for a fresh photo ingest from the Swift app."""
    scanner.begin_scan()
    return {"ok": True}


class IngestBatch(BaseModel):
    records: list[dict[str, Any]]


@app.post("/scan/ingest", status_code=202)
def scan_ingest(body: IngestBatch):
    """Receive a batch of photo metadata from the Swift app."""
    scanner.ingest_batch(body.records)
    return {"ingested": len(body.records)}


class UpdatePath(BaseModel):
    file_path: str

@app.put("/photos/{uuid}/file-path", status_code=200)
def update_file_path(uuid: str, body: UpdatePath):
    """Called by Swift after downloading an iCloud thumbnail to a local cache file."""
    conn = database.get_conn()
    conn.execute(
        "UPDATE photos SET file_path=?, is_local=1 WHERE uuid=?",
        (body.file_path, uuid)
    )
    conn.commit()
    return {"ok": True}


@app.post("/scan/hash", status_code=202)
def scan_hash():
    """Start background pHash computation on already-ingested records."""
    started = scanner.start_hashing()
    return {"started": started}


@app.get("/status", response_model=ScanStatus)
def status():
    s = scanner.get_scan_state()
    conn = database.get_conn()
    cluster_count = conn.execute("SELECT COUNT(*) FROM clusters").fetchone()[0]
    photo_count = conn.execute("SELECT COUNT(*) FROM photos").fetchone()[0]
    skipped_count = conn.execute(
        "SELECT COUNT(*) FROM photos WHERE is_local = 0 OR file_path IS NULL"
    ).fetchone()[0]
    # Map internal states to the display state the Swift app expects
    state = s["state"]
    if state == "ingesting":
        state = "running"
    elif state == "hashing":
        state = "running"
    elif state == "clustering":
        state = "running"
    elif state == "idle" and cluster_count > 0:
        # Server restarted but DB has results from a previous scan — report done
        state = "done"
    start = s.get("scan_start_time")
    elapsed = (time.time() - start) if start and state in ("running", "done", "error") else None
    # During ingestion the Swift app is pushing metadata; Python hasn't started
    # hashing yet so scanned is meaningfully 0.  Using ingested here caused
    # total_photos == scanned → remaining == 0 → ETA showed "~0s" for the first
    # minute of every scan.
    scanned = s["scanned"]
    if state == "done" and scanned == 0:
        scanned = photo_count
    return ScanStatus(
        state=state,
        total_photos=s["total_photos"] or photo_count,
        scanned=scanned,
        skipped_cloud=s["skipped_cloud"] or skipped_count,
        clusters_found=cluster_count,
        error=s.get("error"),
        elapsed_seconds=elapsed,
    )


# ---------------------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------------------

@app.get("/clusters", response_model=list[ClusterSummary])
def list_clusters(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200),
    kind: str | None = None,
):
    offset = (page - 1) * page_size
    conn = database.get_conn()

    where = "WHERE 1=1"
    params: list = []
    if kind:
        where += " AND c.kind = ?"
        params.append(kind)

    rows = conn.execute(f"""
        SELECT c.id, c.kind, c.confidence,
               COUNT(cm.photo_uuid) as member_count,
               MIN(cm.photo_uuid)   as representative_uuid
        FROM clusters c
        JOIN cluster_members cm ON cm.cluster_id = c.id
        {where}
        GROUP BY c.id
        ORDER BY c.confidence DESC, member_count DESC
        LIMIT ? OFFSET ?
    """, params + [page_size, offset]).fetchall()

    return [ClusterSummary(**dict(r)) for r in rows]


@app.get("/clusters/{cluster_id}", response_model=ClusterDetail)
def get_cluster(cluster_id: int):
    conn = database.get_conn()
    cluster = conn.execute(
        "SELECT id, kind, confidence FROM clusters WHERE id = ?", (cluster_id,)
    ).fetchone()
    if not cluster:
        raise HTTPException(status_code=404, detail="Cluster not found")

    rows = conn.execute("""
        SELECT p.* FROM photos p
        JOIN cluster_members cm ON cm.photo_uuid = p.uuid
        WHERE cm.cluster_id = ?
        ORDER BY p.date_taken ASC
    """, (cluster_id,)).fetchall()

    photos = [
        PhotoMeta(
            uuid=r["uuid"],
            local_identifier=r["local_identifier"],
            filename=r["filename"],
            original_filename=r["original_filename"],
            date_taken=r["date_taken"],
            burst_uuid=r["burst_uuid"],
            is_raw=bool(r["is_raw"]),
            is_live=bool(r["is_live"]),
            width=r["width"],
            height=r["height"],
            is_local=bool(r["is_local"]),
            file_path=r["file_path"],
            phash=r["phash"],
        )
        for r in rows
    ]

    return ClusterDetail(
        id=cluster["id"], kind=cluster["kind"],
        confidence=cluster["confidence"], photos=photos
    )


# ---------------------------------------------------------------------------
# Thumbnails — reads file_path provided by Swift; never touches Photos library
# ---------------------------------------------------------------------------

@app.get("/photos/{uuid}/thumbnail")
def get_thumbnail(uuid: str, size: int = Query(default=400, ge=50, le=1200)):
    conn = database.get_conn()
    row = conn.execute(
        "SELECT file_path FROM photos WHERE uuid = ?", (uuid,)
    ).fetchone()

    if not row or not row["file_path"]:
        raise HTTPException(status_code=404, detail="No local file path for this photo")

    path = row["file_path"]
    if not Path(path).exists():
        raise HTTPException(status_code=404, detail=f"File not found on disk: {path}")

    try:
        from PIL import Image
        with Image.open(path) as img:
            img.thumbnail((size, size))
            img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=85)
            return Response(content=buf.getvalue(), media_type="image/jpeg")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8765, reload=False)

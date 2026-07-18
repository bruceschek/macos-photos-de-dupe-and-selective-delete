from pydantic import BaseModel
from typing import Optional


class PhotoMeta(BaseModel):
    uuid: str
    local_identifier: Optional[str]
    filename: str
    original_filename: Optional[str]
    date_taken: Optional[float]
    burst_uuid: Optional[str]
    is_raw: bool
    is_live: bool
    width: Optional[int]
    height: Optional[int]
    is_local: bool
    file_path: Optional[str] = None
    phash: Optional[str]


class ClusterSummary(BaseModel):
    id: int
    kind: str
    confidence: float
    member_count: int
    representative_uuid: str


class ClusterDetail(BaseModel):
    id: int
    kind: str
    confidence: float
    photos: list[PhotoMeta]


class ScanStatus(BaseModel):
    state: str           # 'idle' | 'running' | 'done' | 'error'
    total_photos: int
    scanned: int
    skipped_cloud: int
    clusters_found: int
    error: Optional[str] = None
    elapsed_seconds: Optional[float] = None

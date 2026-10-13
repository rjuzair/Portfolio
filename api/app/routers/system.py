from fastapi import APIRouter

from ..deps import Cursor
from ..models import Health

router = APIRouter(prefix="/api", tags=["system"])


@router.get("/health", response_model=Health)
def health(cur: Cursor) -> Health:
    cur.execute("SELECT VERSION() AS version")
    return Health(status="ok", database=cur.fetchone()["version"])

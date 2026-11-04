import time

from fastapi import APIRouter

from app.rexhub import __version__
from app.rexhub.schemas import HealthResponse

router = APIRouter(prefix="/api", tags=["system"])


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(ok=True, name="RexHub", version=__version__, time=int(time.time()))

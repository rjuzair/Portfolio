"""Application factory: `uvicorn app.main:app`."""

import logging
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.staticfiles import StaticFiles

from .config import Settings, get_settings
from .db import Database
from .errors import install_error_handlers
from .routers import bookings, flights, insights, system

log = logging.getLogger("app")
STATIC_DIR = Path(__file__).parent / "static"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    logging.basicConfig(
        level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.db = Database(settings)
        yield
        app.state.db.close()

    app = FastAPI(
        title="Flight Reservation API",
        version="2.0.0",
        summary="Search flights, book seats, pay, pick seats, cancel — over a MySQL database "
        "that enforces every business rule itself.",
        lifespan=lifespan,
    )
    app.state.settings = settings
    install_error_handlers(app)

    @app.middleware("http")
    async def request_context(request: Request, call_next) -> Response:
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex[:16]
        started = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - started) * 1000
        response.headers["X-Request-ID"] = request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        if request.url.path.startswith("/api/"):
            log.info(
                "%s %s %s %.1fms request_id=%s",
                request.method,
                request.url.path,
                response.status_code,
                elapsed_ms,
                request_id,
            )
        return response

    for module in (system, flights, bookings, insights):
        app.include_router(module.router)
    if STATIC_DIR.is_dir():
        app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="web")
    return app


app = create_app()

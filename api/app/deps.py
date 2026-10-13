"""FastAPI dependencies."""

import secrets
from collections.abc import Iterator
from typing import Annotated

from fastapi import Depends, Header, Request
from pymysql.cursors import DictCursor

from .config import Settings
from .errors import ApiError


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_cursor(request: Request) -> Iterator[DictCursor]:
    with request.app.state.db.cursor() as cur:
        yield cur


Cursor = Annotated[DictCursor, Depends(get_cursor)]


def require_insights_key(
    request: Request, x_api_key: Annotated[str | None, Header()] = None
) -> None:
    expected = request.app.state.settings.insights_api_key
    if expected and not (x_api_key and secrets.compare_digest(x_api_key, expected)):
        raise ApiError(401, "UNAUTHORIZED", "A valid X-API-Key header is required")

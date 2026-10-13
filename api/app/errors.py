"""Translate database errors into RFC 9457 problem responses.

The stored procedures raise SQLSTATE 45000 with an application error number.
The number's hundreds digit encodes the HTTP class:
  70xx → 404 Not Found, 71xx → 409 Conflict, 72xx → 422 Unprocessable.
"""

import logging

import pymysql
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .db import errno_of

log = logging.getLogger(__name__)

ERROR_NAMES: dict[int, str] = {
    7001: "FLIGHT_NOT_FOUND",
    7002: "BOOKING_NOT_FOUND",
    7003: "PASSENGER_NOT_ON_BOOKING",
    7004: "ROUTE_NOT_FOUND",
    7005: "AIRCRAFT_NOT_FOUND",
    7101: "INSUFFICIENT_SEATS",
    7102: "ALREADY_PAID",
    7103: "BOOKING_NOT_ACTIVE",
    7104: "SEAT_TAKEN",
    7105: "PASSENGER_LIST_FULL",
    7106: "DUPLICATE_PASSENGER",
    7107: "PASSENGER_ALREADY_TICKETED",
    7108: "FLIGHT_DEPARTED",
    7109: "ILLEGAL_STATUS_TRANSITION",
    7110: "BOOKING_IMMUTABLE",
    7111: "PAYMENT_IMMUTABLE",
    7201: "CONTACT_REQUIRED",
    7202: "PASSENGERS_INCOMPLETE",
    7203: "INVALID_CARD",
    7204: "INVALID_SEAT",
    7205: "BOOKING_NOT_PAID",
    7206: "INVALID_PASSENGER_COUNT",
    1062: "DUPLICATE",
    3819: "CONSTRAINT_VIOLATION",  # MySQL CHECK constraint
    4025: "CONSTRAINT_VIOLATION",  # MariaDB CHECK constraint
}

TITLES = {
    401: "Unauthorized",
    404: "Not Found",
    409: "Conflict",
    422: "Unprocessable Content",
    503: "Service Unavailable",
}


def status_for(errno: int) -> int | None:
    if 7000 <= errno < 7100:
        return 404
    if 7100 <= errno < 7200 or errno == 1062:
        return 409
    if 7200 <= errno < 7300 or errno in (3819, 4025):
        return 422
    return None


def problem(status: int, error: str, detail: str, **extra) -> JSONResponse:
    body = {
        "type": "about:blank",
        "title": TITLES.get(status, "Error"),
        "status": status,
        "error": error,
        "detail": detail,
        **extra,
    }
    return JSONResponse(body, status_code=status, media_type="application/problem+json")


class ApiError(Exception):
    """An error raised by the API itself, rendered as a problem response."""

    def __init__(self, status: int, error: str, detail: str) -> None:
        super().__init__(detail)
        self.status, self.error, self.detail = status, error, detail


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def api_error(_: Request, exc: ApiError) -> JSONResponse:
        return problem(exc.status, exc.error, exc.detail)

    @app.exception_handler(pymysql.MySQLError)
    async def database_error(request: Request, exc: pymysql.MySQLError) -> JSONResponse:
        errno = errno_of(exc)
        if errno in (1205, 1213):  # lock wait timeout / deadlock: safe to retry
            response = problem(503, "TRY_AGAIN", "The system is busy; please retry.", code=errno)
            response.headers["Retry-After"] = "1"
            return response
        status = status_for(errno) if errno is not None else None
        if status is None:
            log.exception(
                "unexpected database error on %s %s", request.method, request.url.path, exc_info=exc
            )
            return problem(500, "DATABASE_ERROR", "The request could not be completed.")
        message = exc.args[1] if len(exc.args) > 1 else str(exc)
        return problem(status, ERROR_NAMES.get(errno, "ERROR"), message, code=errno)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        errors = [{"loc": list(e["loc"]), "msg": e["msg"]} for e in exc.errors()]
        return problem(422, "VALIDATION_FAILED", "The request is not valid.", errors=errors)

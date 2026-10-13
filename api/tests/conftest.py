"""Integration tests against a real MySQL 8 / MariaDB server.

Environment (defaults suit `docker compose up db` / CI):
  TEST_DB_HOST, TEST_DB_PORT              server address (127.0.0.1:3306)
  TEST_DB_ADMIN_USER, TEST_DB_ADMIN_PASSWORD
                                          an account that may create databases,
                                          users and roles (root / root). On
                                          MariaDB it must also have created the
                                          flight_* roles, or hold them WITH
                                          ADMIN OPTION, to grant them.
  TEST_DB_NAME                            scratch database, rebuilt on every run
                                          (flight_reservations_test)

The app under test connects as the least-privileged API account, exactly as
in production; fixtures and assertions use the admin account.
"""

import os
import uuid
from collections.abc import Iterator
from datetime import date
from types import SimpleNamespace

import pymysql
import pytest
from fastapi.testclient import TestClient
from pymysql.cursors import DictCursor

from app.config import Settings
from app.db import Database
from app.main import create_app

from .sqlloader import run_file, schema_modules

HOST = os.getenv("TEST_DB_HOST", "127.0.0.1")
PORT = int(os.getenv("TEST_DB_PORT", "3306"))
ADMIN_USER = os.getenv("TEST_DB_ADMIN_USER", "root")
ADMIN_PASSWORD = os.getenv("TEST_DB_ADMIN_PASSWORD", "root")
DB_NAME = os.getenv("TEST_DB_NAME", "flight_reservations_test")
API_USER = "booking_api_test"
API_PASSWORD = "test-only-password"

# Every fixture flight departs next year, so it is always bookable
YEAR = date.today().year + 1


def admin_connection(database: str | None = DB_NAME) -> pymysql.Connection:
    return pymysql.connect(
        host=HOST,
        port=PORT,
        user=ADMIN_USER,
        password=ADMIN_PASSWORD,
        database=database,
        autocommit=True,
        cursorclass=DictCursor,
        charset="utf8mb4",
    )


def _build_database() -> None:
    with admin_connection(None) as conn, conn.cursor() as cur:
        cur.execute(f"DROP DATABASE IF EXISTS `{DB_NAME}`")
        cur.execute(f"CREATE DATABASE `{DB_NAME}` CHARACTER SET utf8mb4")
        cur.execute(f"USE `{DB_NAME}`")
        for module in schema_modules():
            run_file(cur, module)

        cur.execute("SELECT VERSION() AS v")
        mariadb = "mariadb" in cur.fetchone()["v"].lower()
        cur.execute(f"CREATE USER IF NOT EXISTS '{API_USER}'@'%' IDENTIFIED BY '{API_PASSWORD}'")
        cur.execute(f"GRANT flight_api TO '{API_USER}'@'%'")
        keyword = "FOR" if mariadb else "TO"
        cur.execute(f"SET DEFAULT ROLE flight_api {keyword} '{API_USER}'@'%'")


def _reference_data() -> SimpleNamespace:
    """Two airports, a 4-seat and a 40-seat aircraft, weekly flights next year."""
    with admin_connection() as conn, conn.cursor() as cur:
        for sql in (
            f"CALL addYear({YEAR}, 2.0)",
            f"CALL addDay({YEAR}, 'Monday', 1.0)",
            f"CALL addDay({YEAR}, 'Friday', 1.5)",
            "CALL addDestination('ARN', 'Stockholm Arlanda', 'Sweden')",
            "CALL addDestination('LHR', 'London Heathrow', 'United Kingdom')",
            "CALL addAircraft('MINI4', 'Four-seater', 2, 2)",
            f"CALL addRoute('ARN', 'LHR', {YEAR}, 50)",
            f"CALL addRoute('LHR', 'ARN', {YEAR}, 60)",
            f"CALL addFlight('ARN', 'LHR', {YEAR}, 'Monday', '07:00:00')",
            f"CALL addFlightWithAircraft('ARN', 'LHR', {YEAR}, 'Friday', '18:00:00', 'MINI4')",
            f"CALL addFlight('LHR', 'ARN', {YEAR}, 'Friday', '12:00:00')",
        ):
            cur.execute(sql)
        cur.execute("SELECT MIN(flight_id) AS first, MAX(flight_id) AS last FROM flights_info")
        ids = cur.fetchone()
    return SimpleNamespace(year=YEAR, first_flight=ids["first"], last_flight=ids["last"])


@pytest.fixture(scope="session")
def reference() -> SimpleNamespace:
    _build_database()
    return _reference_data()


@pytest.fixture(scope="session")
def settings(reference) -> Settings:
    return Settings(
        db_host=HOST,
        db_port=PORT,
        db_name=DB_NAME,
        db_user=API_USER,
        db_password=API_PASSWORD,
        db_pool_size=20,
    )


@pytest.fixture(scope="session")
def client(settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


@pytest.fixture
def api_db(settings) -> Iterator[Database]:
    """The API's own connection pool, for tests that bypass HTTP."""
    db = Database(settings)
    yield db
    db.close()


@pytest.fixture
def admin() -> Iterator[DictCursor]:
    with admin_connection() as conn, conn.cursor() as cur:
        yield cur


class Flights:
    """Picks a distinct, untouched flight for each test."""

    def __init__(self) -> None:
        self._used: set[int] = set()

    def fresh(self, aircraft: str = "STD40", origin: str = "ARN") -> int:
        with admin_connection() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT flight_id FROM v_flight_availability "
                "WHERE aircraft_code = %s AND departure_airport = %s AND seats_booked = 0 "
                "ORDER BY flight_id",
                (aircraft, origin),
            )
            for row in cur.fetchall():
                if row["flight_id"] not in self._used:
                    self._used.add(row["flight_id"])
                    return row["flight_id"]
        raise RuntimeError("ran out of fixture flights")


@pytest.fixture(scope="session")
def flights(reference) -> Flights:
    return Flights()


def book(
    client: TestClient,
    flight_id: int,
    names: list[str],
    *,
    pay: bool = True,
    card: str = "4111 1111 1111 1111",
) -> dict:
    """Runs the booking workflow over HTTP and returns the final booking."""
    response = client.post("/api/bookings", json={"flight_id": flight_id, "passengers": len(names)})
    assert response.status_code == 201, response.text
    ref = response.json()["booking_ref"]
    for name in names:
        passport = f"P{uuid.uuid4().hex[:10].upper()}"
        response = client.post(
            f"/api/bookings/{ref}/passengers", json={"passport": passport, "name": name}
        )
        assert response.status_code == 201, response.text
    lead = response.json()["passengers"][0]["passport"]
    response = client.put(
        f"/api/bookings/{ref}/contact",
        json={"passport": lead, "email": "lead@example.com", "phone": "+46 70 123 45 67"},
    )
    assert response.status_code == 200, response.text
    if pay:
        response = client.post(
            f"/api/bookings/{ref}/payment", json={"cardholder": names[0], "card_number": card}
        )
        assert response.status_code == 200, response.text
    return response.json()

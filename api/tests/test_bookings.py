from decimal import Decimal

import pymysql
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.errors import install_error_handlers

from .conftest import book


def test_full_booking_lifecycle(client, flights, admin):
    flight_id = flights.fresh()
    fare = Decimal(client.get(f"/api/flights/{flight_id}").json()["price_per_seat"])

    created = client.post("/api/bookings", json={"flight_id": flight_id, "passengers": 2})
    assert created.status_code == 201
    booking = created.json()
    ref = booking["booking_ref"]
    assert len(ref) == 6 and booking["status"] == "PENDING"
    assert booking["passengers"] == [] and booking["payment"] is None

    client.post(f"/api/bookings/{ref}/passengers", json={"passport": "AB1234567", "name": "Ada"})
    client.post(f"/api/bookings/{ref}/passengers", json={"passport": "CD7654321", "name": "Alan"})
    client.put(
        f"/api/bookings/{ref}/contact",
        json={"passport": "AB1234567", "email": "ada@example.com", "phone": "+44 20 7946"},
    )
    paid = client.post(
        f"/api/bookings/{ref}/payment",
        json={"cardholder": "Ada Lovelace", "card_number": "5555-5555-5555-4444"},
    )
    assert paid.status_code == 200
    booking = paid.json()
    assert booking["status"] == "CONFIRMED"
    assert Decimal(booking["payment"]["amount"]) == fare * 2
    assert booking["payment"]["card_brand"] == "MASTERCARD"
    assert booking["payment"]["card_last4"] == "4444"
    assert all(p["ticket"] for p in booking["passengers"])
    assert booking["contact"]["email"] == "ada@example.com"

    seat = client.put(f"/api/bookings/{ref.lower()}/passengers/AB1234567/seat", json={"seat": "3c"})
    assert seat.status_code == 200
    assert {p["passport"]: p["seat"] for p in seat.json()["passengers"]}["AB1234567"] == "3C"
    flight = client.get(f"/api/flights/{flight_id}").json()
    assert flight["free_seats"] == 38
    assert Decimal(flight["price_per_seat"]) > fare, "the fare rises as seats sell"

    quote = client.get(f"/api/bookings/{ref}/refund-quote").json()
    assert Decimal(quote["refund_if_cancelled_now"]) == fare * 2, "> 30 days out: full refund"

    cancelled = client.post(f"/api/bookings/{ref}/cancel")
    assert cancelled.status_code == 200
    assert Decimal(cancelled.json()["refund"]) == fare * 2
    assert cancelled.json()["booking"]["status"] == "CANCELLED"
    assert client.get(f"/api/flights/{flight_id}").json()["free_seats"] == 40

    admin.execute(
        "SELECT COUNT(*) AS n FROM audit_log a JOIN reservation r "
        "ON a.table_name = 'reservation' AND a.record_id = r.res_no "
        "WHERE r.booking_ref = %s",
        (ref,),
    )
    assert admin.fetchone()["n"] == 3, "created, confirmed, cancelled"


def test_card_number_is_never_returned_or_stored(client, flights, admin):
    booking = book(client, flights.fresh(), ["Grace Hopper"], card="4111111111111111")
    assert "4111111111111111" not in str(booking)
    admin.execute(
        "SELECT COUNT(*) AS n FROM payment WHERE card_last4 = '1111' "
        "AND CONCAT_WS('|', cardholder_name, card_brand, card_last4) LIKE '%41111111%'"
    )
    assert admin.fetchone()["n"] == 0


def test_unknown_booking(client):
    response = client.get("/api/bookings/ZZZZZZ")
    assert response.status_code == 404
    assert response.json()["error"] == "BOOKING_NOT_FOUND"


def test_business_rule_violations_map_to_http_status(client, flights):
    flight_id = flights.fresh()
    ref = client.post("/api/bookings", json={"flight_id": flight_id, "passengers": 2}).json()[
        "booking_ref"
    ]
    client.post(f"/api/bookings/{ref}/passengers", json={"passport": "EF1111111", "name": "Edsger"})

    def error(response, status, name):
        assert response.status_code == status, response.text
        assert response.json()["error"] == name
        return response.json()

    body = error(
        client.post(
            f"/api/bookings/{ref}/payment",
            json={"cardholder": "E", "card_number": "4111111111111111"},
        ),
        422,
        "PASSENGERS_INCOMPLETE",
    )
    assert body["code"] == 7202
    error(
        client.post(
            f"/api/bookings/{ref}/passengers",
            json={"passport": "EF1111111", "name": "Edsger again"},
        ),
        409,
        "DUPLICATE_PASSENGER",
    )
    client.post(
        f"/api/bookings/{ref}/passengers", json={"passport": "GH2222222", "name": "Barbara"}
    )
    error(
        client.post(
            f"/api/bookings/{ref}/passengers", json={"passport": "IJ3333333", "name": "Donald"}
        ),
        409,
        "PASSENGER_LIST_FULL",
    )
    error(
        client.put(
            f"/api/bookings/{ref}/contact",
            json={"passport": "XX9999999", "email": "x@example.com", "phone": "12345"},
        ),
        404,
        "PASSENGER_NOT_ON_BOOKING",
    )
    error(
        client.post(
            f"/api/bookings/{ref}/payment",
            json={"cardholder": "E", "card_number": "4111111111111111"},
        ),
        422,
        "CONTACT_REQUIRED",
    )
    client.put(
        f"/api/bookings/{ref}/contact",
        json={"passport": "EF1111111", "email": "e@example.com", "phone": "12345"},
    )
    error(
        client.post(
            f"/api/bookings/{ref}/payment",
            json={"cardholder": "E", "card_number": "4111111111111112"},
        ),
        422,
        "INVALID_CARD",
    )
    error(
        client.put(f"/api/bookings/{ref}/passengers/EF1111111/seat", json={"seat": "1A"}),
        422,
        "BOOKING_NOT_PAID",
    )
    client.post(
        f"/api/bookings/{ref}/payment", json={"cardholder": "E", "card_number": "4111111111111111"}
    )
    error(
        client.post(
            f"/api/bookings/{ref}/payment",
            json={"cardholder": "E", "card_number": "4111111111111111"},
        ),
        409,
        "ALREADY_PAID",
    )
    error(
        client.put(f"/api/bookings/{ref}/passengers/EF1111111/seat", json={"seat": "40A"}),
        422,
        "INVALID_SEAT",
    )
    client.put(f"/api/bookings/{ref}/passengers/EF1111111/seat", json={"seat": "5A"})
    error(
        client.put(f"/api/bookings/{ref}/passengers/GH2222222/seat", json={"seat": "5A"}),
        409,
        "SEAT_TAKEN",
    )


def test_cannot_reserve_more_seats_than_the_aircraft_has(client, flights):
    response = client.post(
        "/api/bookings", json={"flight_id": flights.fresh("MINI4"), "passengers": 5}
    )
    assert response.status_code == 409
    assert response.json()["error"] == "INSUFFICIENT_SEATS"


def test_request_validation_uses_problem_format(client, flights):
    ref = client.post("/api/bookings", json={"flight_id": flights.fresh(), "passengers": 1}).json()[
        "booking_ref"
    ]
    response = client.post(f"/api/bookings/{ref}/passengers", json={"passport": "AB1234567"})
    assert response.status_code == 422
    body = response.json()
    assert body["error"] == "VALIDATION_FAILED"
    assert body["errors"][0]["loc"] == ["body", "name"]

    response = client.post(
        f"/api/bookings/{ref}/payment", json={"cardholder": "X", "card_number": "not a card"}
    )
    assert response.status_code == 422
    assert "not a card" not in response.text, "the card input is never echoed back"


def test_a_cancelled_booking_cannot_be_changed(client, flights):
    booking = book(client, flights.fresh(), ["Ken Thompson"])
    ref = booking["booking_ref"]
    assert client.post(f"/api/bookings/{ref}/cancel").status_code == 200
    response = client.post(f"/api/bookings/{ref}/cancel")
    assert response.status_code == 409
    assert response.json()["error"] == "BOOKING_NOT_ACTIVE"


def test_deadlocks_become_retryable_503s():
    app = FastAPI()
    install_error_handlers(app)

    @app.get("/deadlock")
    def deadlock():
        raise pymysql.err.OperationalError(1213, "Deadlock found when trying to get lock")

    response = TestClient(app).get("/deadlock")
    assert response.status_code == 503
    assert response.headers["Retry-After"] == "1"
    assert response.json()["error"] == "TRY_AGAIN"

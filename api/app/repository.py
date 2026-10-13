"""All SQL the API runs. Reads use the views, writes call the procedures.

Functions take a cursor so a request can make several calls on one
connection (stored-procedure OUT parameters live in session variables).
"""

from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any

from pymysql.cursors import DictCursor

from .errors import ApiError
from .models import (
    Airport,
    Booking,
    BookingFlight,
    Contact,
    Flight,
    Passenger,
    Payment,
    Seat,
    SeatMap,
)


def _as_time(value: timedelta | time) -> time:
    # PyMySQL returns TIME columns as timedelta
    if isinstance(value, timedelta):
        return (datetime.min + value).time()
    return value


# ---------------------------------------------------------------------------
# Flights
# ---------------------------------------------------------------------------

_FLIGHT_COLUMNS = """
    flight_id, departure_airport, departure_airport_name, departure_country,
    arrival_airport, arrival_airport_name, arrival_country, departure_date,
    departure_time, departs_at, aircraft_code, aircraft_model, capacity,
    free_seats, price_per_seat"""


def _flight(row: dict[str, Any], passengers: int | None = None) -> Flight:
    return Flight(
        flight_id=row["flight_id"],
        origin=Airport(
            code=row["departure_airport"],
            name=row["departure_airport_name"],
            country=row["departure_country"],
        ),
        destination=Airport(
            code=row["arrival_airport"],
            name=row["arrival_airport_name"],
            country=row["arrival_country"],
        ),
        departure_date=row["departure_date"],
        departure_time=_as_time(row["departure_time"]),
        departs_at=row["departs_at"],
        aircraft_code=row["aircraft_code"],
        aircraft_model=row["aircraft_model"],
        capacity=row["capacity"],
        free_seats=row["free_seats"],
        price_per_seat=row["price_per_seat"],
        total_price=row["price_per_seat"] * passengers if passengers else None,
    )


def list_airports(cur: DictCursor) -> list[Airport]:
    cur.execute(
        "SELECT airport_id AS code, airport_name AS name, country "
        "FROM airport ORDER BY airport_name"
    )
    return [Airport(**row) for row in cur.fetchall()]


def search_flights(
    cur: DictCursor,
    *,
    origin: str | None,
    destination: str | None,
    date_from: date,
    date_to: date,
    passengers: int,
    limit: int,
) -> list[Flight]:
    where = ["departure_date BETWEEN %s AND %s", "departs_at > NOW()", "free_seats >= %s"]
    params: list[Any] = [date_from, date_to, passengers]
    if origin:
        where.append("departure_airport = %s")
        params.append(origin.upper())
    if destination:
        where.append("arrival_airport = %s")
        params.append(destination.upper())
    params.append(limit)
    cur.execute(
        # only fixed SQL fragments are joined in; every value is a bound parameter
        f"SELECT {_FLIGHT_COLUMNS} FROM v_flight_availability "
        f"WHERE {' AND '.join(where)} ORDER BY departs_at, flight_id LIMIT %s",
        params,
    )
    return [_flight(row, passengers) for row in cur.fetchall()]


def get_flight(cur: DictCursor, flight_id: int) -> Flight:
    cur.execute(
        f"SELECT {_FLIGHT_COLUMNS} FROM v_flight_availability WHERE flight_id = %s", (flight_id,)
    )
    row = cur.fetchone()
    if row is None:
        raise ApiError(404, "FLIGHT_NOT_FOUND", "The flight does not exist")
    return _flight(row)


def seat_map(cur: DictCursor, flight_id: int) -> SeatMap:
    flight = get_flight(cur, flight_id)
    cur.execute("CALL getSeatMap(%s)", (flight_id,))
    rows = cur.fetchall()
    seats = [
        Seat(
            seat_no=r["seat_no"],
            row=r["seat_row"],
            letter=r["seat_letter"],
            taken=bool(r["is_taken"]),
        )
        for r in rows
    ]
    return SeatMap(
        flight_id=flight_id,
        aircraft_code=flight.aircraft_code,
        aircraft_model=flight.aircraft_model,
        rows=max(s.row for s in seats),
        seats_per_row=len({s.letter for s in seats}),
        seats=seats,
    )


# ---------------------------------------------------------------------------
# Bookings
# ---------------------------------------------------------------------------


def _booking_row(cur: DictCursor, booking_ref: str) -> dict[str, Any]:
    cur.execute("SELECT * FROM v_booking WHERE booking_ref = %s", (booking_ref.upper(),))
    row = cur.fetchone()
    if row is None:
        raise ApiError(404, "BOOKING_NOT_FOUND", "No booking with this reference")
    return row


def res_no_for(cur: DictCursor, booking_ref: str) -> int:
    """The internal reservation number. It never leaves the API."""
    return _booking_row(cur, booking_ref)["res_no"]


def get_booking(cur: DictCursor, booking_ref: str) -> Booking:
    row = _booking_row(cur, booking_ref)
    cur.execute(
        "SELECT passp_no, name, ticket, seat_no, is_contact FROM v_booking_passengers "
        "WHERE booking_ref = %s ORDER BY ticket IS NULL, ticket, passp_no",
        (row["booking_ref"],),
    )
    passengers = [
        Passenger(
            passport=p["passp_no"],
            name=p["name"],
            ticket=p["ticket"],
            seat=p["seat_no"],
            is_contact=bool(p["is_contact"]),
        )
        for p in cur.fetchall()
    ]
    contact = None
    if row["contact_passport"] is not None:
        contact = Contact(
            passport=row["contact_passport"], email=row["contact_email"], phone=row["contact_phone"]
        )
    payment = None
    if row["amount_paid"] is not None:
        payment = Payment(
            amount=row["amount_paid"],
            refunded_amount=row["refunded_amount"],
            card_brand=row["card_brand"],
            card_last4=row["card_last4"],
            paid_at=row["paid_at"],
            refunded_at=row["refunded_at"],
        )
    return Booking(
        booking_ref=row["booking_ref"],
        status=row["status"],
        passengers_expected=row["no_passengers"],
        flight=BookingFlight(
            flight_id=row["flight_id"],
            origin=Airport(code=row["departure_airport"], name=row["departure_airport_name"]),
            destination=Airport(code=row["arrival_airport"], name=row["arrival_airport_name"]),
            departure_date=row["departure_date"],
            departure_time=_as_time(row["departure_time"]),
            departs_at=row["departs_at"],
            aircraft_code=row["aircraft_code"],
        ),
        passengers=passengers,
        contact=contact,
        payment=payment,
        created_at=row["created_at"],
    )


def create_booking(cur: DictCursor, flight_id: int, passengers: int) -> str:
    cur.execute("CALL createReservation(%s, %s, @res_no, @booking_ref)", (flight_id, passengers))
    cur.execute("SELECT @booking_ref AS booking_ref")
    return cur.fetchone()["booking_ref"]


def add_passenger(cur: DictCursor, booking_ref: str, passport: str, name: str) -> None:
    cur.execute("CALL addPassenger(%s, %s, %s)", (res_no_for(cur, booking_ref), passport, name))


def set_contact(cur: DictCursor, booking_ref: str, passport: str, email: str, phone: str) -> None:
    cur.execute(
        "CALL addContact(%s, %s, %s, %s)", (res_no_for(cur, booking_ref), passport, email, phone)
    )


def pay(cur: DictCursor, booking_ref: str, cardholder: str, card_number: str) -> None:
    cur.execute(
        "CALL addPayment(%s, %s, %s)", (res_no_for(cur, booking_ref), cardholder, card_number)
    )


def assign_seat(cur: DictCursor, booking_ref: str, passport: str, seat: str) -> None:
    cur.execute("CALL assignSeat(%s, %s, %s)", (res_no_for(cur, booking_ref), passport, seat))


def cancel(cur: DictCursor, booking_ref: str) -> Decimal:
    cur.execute("CALL cancelReservation(%s, @refund)", (res_no_for(cur, booking_ref),))
    cur.execute("SELECT @refund AS refund")
    return Decimal(cur.fetchone()["refund"])


def refund_quote(cur: DictCursor, booking_ref: str) -> tuple[Decimal | None, Decimal]:
    row = _booking_row(cur, booking_ref)
    cur.execute("SELECT calculateRefund(%s, NOW()) AS refund", (row["res_no"],))
    return row["amount_paid"], Decimal(cur.fetchone()["refund"])


# ---------------------------------------------------------------------------
# Insights (analytics views; flight_analyst role)
# ---------------------------------------------------------------------------


def funnel(cur: DictCursor) -> dict[str, Any]:
    cur.execute("SELECT * FROM v_booking_funnel")
    row = cur.fetchone()
    # the SUMs are NULL while there are no reservations yet
    return {**{k: v or 0 for k, v in row.items()}, "conversion_pct": row["conversion_pct"]}


def revenue_totals(cur: DictCursor) -> tuple[Decimal, int]:
    cur.execute(
        "SELECT COALESCE(SUM(net_revenue), 0) AS net, COALESCE(SUM(passengers), 0) AS pax "
        "FROM v_monthly_revenue"
    )
    row = cur.fetchone()
    return Decimal(row["net"]), int(row["pax"])


def route_performance(cur: DictCursor, year: int) -> list[dict[str, Any]]:
    cur.execute(
        "SELECT * FROM v_route_performance WHERE year = %s ORDER BY revenue_rank, route_id", (year,)
    )
    return cur.fetchall()


def monthly_revenue(cur: DictCursor) -> list[dict[str, Any]]:
    cur.execute("SELECT * FROM v_monthly_revenue ORDER BY travel_month")
    return cur.fetchall()


def upcoming_load(cur: DictCursor, days: int) -> list[dict[str, Any]]:
    cur.execute(
        """SELECT departure_airport, arrival_airport,
                  COUNT(*)                                        AS flights,
                  SUM(capacity)                                   AS capacity,
                  SUM(seats_booked)                               AS seats_booked,
                  ROUND(100 * SUM(seats_booked) / SUM(capacity), 1) AS load_factor_pct,
                  SUM(net_revenue)                                AS net_revenue
           FROM v_flight_load
           WHERE departure_date BETWEEN CURDATE() AND CURDATE() + INTERVAL %s DAY
           GROUP BY departure_airport, arrival_airport
           ORDER BY load_factor_pct DESC, departure_airport, arrival_airport""",
        (days,),
    )
    return cur.fetchall()

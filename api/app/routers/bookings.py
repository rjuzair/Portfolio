"""The booking workflow: create → passengers → contact → pay → seats / cancel.

Each endpoint is one stored procedure call; the database enforces the rules
and its error numbers become HTTP status codes (see app/errors.py).
"""

from typing import Annotated

from fastapi import APIRouter, Path, status

from .. import repository
from ..deps import Cursor
from ..models import (
    Booking,
    Cancellation,
    ContactDetails,
    CreateBooking,
    NewPassenger,
    PaymentDetails,
    RefundQuote,
    SeatSelection,
)

router = APIRouter(prefix="/api/bookings", tags=["bookings"])

BookingRef = Annotated[str, Path(pattern=r"^[A-Za-z0-9]{6}$", examples=["K7Q2MX"])]
Passport = Annotated[str, Path(min_length=5, max_length=20, pattern=r"^[A-Za-z0-9-]+$")]


@router.post(
    "",
    response_model=Booking,
    status_code=status.HTTP_201_CREATED,
    summary="Reserve seats on a flight",
)
def create_booking(body: CreateBooking, cur: Cursor) -> Booking:
    """Creates a PENDING booking. Seats are only taken once it is paid."""
    booking_ref = repository.create_booking(cur, body.flight_id, body.passengers)
    return repository.get_booking(cur, booking_ref)


@router.get("/{booking_ref}", response_model=Booking)
def get_booking(booking_ref: BookingRef, cur: Cursor) -> Booking:
    return repository.get_booking(cur, booking_ref)


@router.post(
    "/{booking_ref}/passengers", response_model=Booking, status_code=status.HTTP_201_CREATED
)
def add_passenger(booking_ref: BookingRef, body: NewPassenger, cur: Cursor) -> Booking:
    repository.add_passenger(cur, booking_ref, body.passport, body.name)
    return repository.get_booking(cur, booking_ref)


@router.put("/{booking_ref}/contact", response_model=Booking)
def set_contact(booking_ref: BookingRef, body: ContactDetails, cur: Cursor) -> Booking:
    repository.set_contact(cur, booking_ref, body.passport, body.email, body.phone)
    return repository.get_booking(cur, booking_ref)


@router.post("/{booking_ref}/payment", response_model=Booking, summary="Pay and issue tickets")
def pay(booking_ref: BookingRef, body: PaymentDetails, cur: Cursor) -> Booking:
    """Charges the current fare for every passenger and issues tickets.

    The database re-checks seat availability under a row lock, so two
    payments can never sell the same last seats.
    """
    repository.pay(cur, booking_ref, body.cardholder, body.card_number.get_secret_value())
    return repository.get_booking(cur, booking_ref)


@router.put("/{booking_ref}/passengers/{passport}/seat", response_model=Booking)
def choose_seat(
    booking_ref: BookingRef, passport: Passport, body: SeatSelection, cur: Cursor
) -> Booking:
    repository.assign_seat(cur, booking_ref, passport, body.seat)
    return repository.get_booking(cur, booking_ref)


@router.get("/{booking_ref}/refund-quote", response_model=RefundQuote)
def refund_quote(booking_ref: BookingRef, cur: Cursor) -> RefundQuote:
    """What cancelling right now would refund (100 % >= 30 days ahead, 50 % >= 7 days)."""
    amount_paid, refund = repository.refund_quote(cur, booking_ref)
    return RefundQuote(
        booking_ref=booking_ref.upper(), amount_paid=amount_paid, refund_if_cancelled_now=refund
    )


@router.post("/{booking_ref}/cancel", response_model=Cancellation)
def cancel(booking_ref: BookingRef, cur: Cursor) -> Cancellation:
    refund = repository.cancel(cur, booking_ref)
    return Cancellation(booking=repository.get_booking(cur, booking_ref), refund=refund)

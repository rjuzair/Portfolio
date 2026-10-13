"""Request and response schemas (these also drive the OpenAPI document)."""

from datetime import date, datetime, time
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field, SecretStr, field_validator

BookingStatus = Literal["PENDING", "CONFIRMED", "CANCELLED", "EXPIRED"]


class Airport(BaseModel):
    code: str = Field(examples=["ARN"])
    name: str = Field(examples=["Stockholm Arlanda"])
    country: str | None = Field(default=None, examples=["Sweden"])


class Flight(BaseModel):
    flight_id: int
    origin: Airport
    destination: Airport
    departure_date: date
    departure_time: time
    departs_at: datetime
    aircraft_code: str
    aircraft_model: str
    capacity: int
    free_seats: int
    price_per_seat: Decimal = Field(description="Current fare; it rises as the flight fills")
    total_price: Decimal | None = Field(
        default=None, description="price_per_seat x the number of passengers searched for"
    )


class Seat(BaseModel):
    seat_no: str = Field(examples=["12C"])
    row: int
    letter: str
    taken: bool


class SeatMap(BaseModel):
    flight_id: int
    aircraft_code: str
    aircraft_model: str
    rows: int
    seats_per_row: int
    seats: list[Seat]


class Passenger(BaseModel):
    passport: str
    name: str
    ticket: int | None = Field(description="Issued when the booking is paid")
    seat: str | None
    is_contact: bool


class Contact(BaseModel):
    passport: str
    email: str
    phone: str


class Payment(BaseModel):
    amount: Decimal
    refunded_amount: Decimal
    card_brand: str
    card_last4: str
    paid_at: datetime
    refunded_at: datetime | None


class BookingFlight(BaseModel):
    flight_id: int
    origin: Airport
    destination: Airport
    departure_date: date
    departure_time: time
    departs_at: datetime
    aircraft_code: str


class Booking(BaseModel):
    booking_ref: str = Field(examples=["K7Q2MX"])
    status: BookingStatus
    passengers_expected: int
    flight: BookingFlight
    passengers: list[Passenger]
    contact: Contact | None
    payment: Payment | None
    created_at: datetime


class Cancellation(BaseModel):
    booking: Booking
    refund: Decimal


class RefundQuote(BaseModel):
    booking_ref: str
    amount_paid: Decimal | None
    refund_if_cancelled_now: Decimal


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

PASSPORT = Field(min_length=5, max_length=20, pattern=r"^[A-Za-z0-9-]+$", examples=["AB1234567"])


class CreateBooking(BaseModel):
    flight_id: int = Field(gt=0)
    passengers: int = Field(ge=1, le=9, description="Seats to reserve")


class NewPassenger(BaseModel):
    passport: str = PASSPORT
    name: str = Field(min_length=1, max_length=100, examples=["Ada Lovelace"])


class ContactDetails(BaseModel):
    passport: str = PASSPORT
    email: str = Field(
        max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", examples=["ada@example.com"]
    )
    phone: str = Field(pattern=r"^\+?[0-9][0-9 ()-]{3,19}$", examples=["+46 70 123 45 67"])


class PaymentDetails(BaseModel):
    cardholder: str = Field(min_length=1, max_length=100, examples=["Ada Lovelace"])
    # SecretStr keeps the number out of logs and reprs
    card_number: SecretStr = Field(examples=["4111 1111 1111 1111"])

    @field_validator("card_number")
    @classmethod
    def looks_like_a_card(cls, value: SecretStr) -> SecretStr:
        digits = value.get_secret_value().replace(" ", "").replace("-", "")
        if not digits.isdigit() or not 12 <= len(digits) <= 19:
            raise ValueError("a card number has 12-19 digits")
        return value


class SeatSelection(BaseModel):
    seat: str = Field(pattern=r"^[1-9][0-9]?[A-Za-z]$", examples=["12C"])


# ---------------------------------------------------------------------------
# Insights
# ---------------------------------------------------------------------------


class Funnel(BaseModel):
    reservations: int
    pending: int
    confirmed: int
    cancelled: int
    expired: int
    paid: int
    conversion_pct: Decimal | None


class InsightsSummary(BaseModel):
    funnel: Funnel
    net_revenue: Decimal
    passengers_booked: int
    upcoming_days: int
    upcoming_load_factor_pct: Decimal | None


class RoutePerformance(BaseModel):
    route_id: int
    departure_airport: str
    arrival_airport: str
    year: int
    flights: int
    seats_offered: int
    seats_sold: int
    load_factor_pct: Decimal | None
    gross_revenue: Decimal
    refunds: Decimal
    net_revenue: Decimal
    revenue_per_seat: Decimal | None
    revenue_rank: int


class MonthlyRevenue(BaseModel):
    travel_month: str
    paid_bookings: int
    cancelled_bookings: int
    passengers: int
    net_revenue: Decimal
    cumulative_revenue: Decimal
    change_vs_previous_month: Decimal | None


class RouteLoad(BaseModel):
    departure_airport: str
    arrival_airport: str
    flights: int
    capacity: int
    seats_booked: int
    load_factor_pct: Decimal | None
    net_revenue: Decimal


class Health(BaseModel):
    status: Literal["ok"]
    database: str

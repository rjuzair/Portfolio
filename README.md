# Flight Reservation System — Relational Database

A MySQL/MariaDB database for an airline booking system: it models airports, routes, weekly schedules and dynamic pricing, and enforces the booking workflow — **reserve → add passengers → add contact → pay → ticket** — entirely in the database with stored procedures, functions, a trigger and a view.

![MySQL](https://img.shields.io/badge/MySQL-4479A1?logo=mysql&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-003545?logo=mariadb&logoColor=white)

## Data model
[ER diagram](docs/er-diagram.pdf) · [Relational model](docs/relational-model.pdf)

| Table | Purpose |
|---|---|
| `airport` | Airport code, name and country |
| `route` | Departure → arrival airport, year and base price |
| `year`, `week_day` | Yearly profit factor and per-weekday price factor |
| `weekly_schedule` | Recurring departure (route, weekday, time) for a year |
| `flights_info` | One concrete flight per schedule entry and week (52 per year) |
| `reservation` | A booking for *n* passengers on a flight |
| `passenger`, `contact_info` | Passengers on a reservation and the contact person |
| `creditcard_info` | Payment for a reservation |

## Business logic in the database
| Object | Type | Behaviour |
|---|---|---|
| `addYear`, `addDay`, `addDestination`, `addRoute` | Procedures | Maintain reference data |
| `addFlight` | Procedure | Creates a weekly schedule entry and its 52 weekly flights |
| `addReservation` | Procedure | Finds the flight and creates a reservation if enough seats are free |
| `addPassenger`, `addContact` | Procedures | Validate the reservation and passenger before inserting |
| `addPayment` | Procedure | Requires a contact, re-checks seat availability and records the payment at the current price |
| `calculateFreeSeats` | Function | 40 seats minus seats on **paid** reservations |
| `calculatePrice` | Function | `route price × weekday factor × profit factor × (booked passengers + 1) / 40` — the price rises as the flight fills |
| `ticketgenerator` | Trigger | Issues ticket numbers to every passenger once a reservation is paid |
| `allFlights` | View | Every flight with route, departure time, free seats and current price |

## Quick start
```bash
mysql -e "CREATE DATABASE flight_reservations"
mysql flight_reservations < sql/schema.sql
mysql flight_reservations < sql/demo_booking.sql   # example booking workflow
mysql flight_reservations -e "SELECT * FROM allFlights LIMIT 5"
```
Tested on MariaDB 10.11; compatible with MySQL 8.

## Possible improvements
- Store payment tokens from a payment provider instead of raw card numbers, and generate ticket numbers with a collision-free sequence instead of `RAND()`.
- Wrap `addPayment` in a transaction with `SELECT … FOR UPDATE` so two concurrent payments cannot overbook the last seats.
- Add foreign keys to `weekly_schedule.w_year` and indexes on frequently joined columns.

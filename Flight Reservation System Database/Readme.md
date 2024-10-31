# Flight Reservation System Database Schema

This repository provides the SQL schema, procedures, functions, triggers, and a view necessary to implement a flight reservation system. The database structure ensures organized data storage for flights, airports, schedules, routes, reservations, passengers, and payments, facilitating efficient reservation management and reporting. Here’s a breakdown of the components included:

---

## Database Structure

### Tables

1. **`airport`**: Stores airport details.
   - **Columns**: `airport_id` (PK), `country`, `airport_name`

2. **`route`**: Manages routes with departure and arrival airports, year, and price.
   - **Columns**: `route_id` (PK), `departure_ap` (FK), `arrival_ap` (FK), `year`, `price`

3. **`weekly_schedule`**: Stores the weekly flight schedule, including departure times.
   - **Columns**: `w_id` (PK), `w_route_id` (FK), `w_year`, `weekday`, `dept`

4. **`year`**: Holds profit factors for specific years.
   - **Columns**: `year` (PK), `profitfactor`

5. **`week_day`**: Stores day-based pricing factors for each year.
   - **Columns**: `weekday`, `year` (Composite PK), `price_factor`

6. **`flights_info`**: Information about each flight, linked to weekly schedules.
   - **Columns**: `flight_id` (PK), `flight_ws_id` (FK), `week`

7. **`reservation`**: Reservation details linked to flights.
   - **Columns**: `res_no` (PK), `flight_id` (FK), `no_passengers`

8. **`passenger`**: Passenger information tied to reservations.
   - **Columns**: `passp_no`, `res_no` (Composite PK), `name`, `ticket`

9. **`contact_info`**: Contact details for passengers on reservations.
   - **Columns**: `passp_no`, `res_no` (Composite PK), `phone`, `email`

10. **`creditcard_info`**: Stores payment information linked to reservations.
    - **Columns**: `res_no` (PK), `card_no`, `name`, `amount`

### Procedures

- **`addYear`**: Adds a year and profit factor to the `year` table.
- **`addDay`**: Adds a day and pricing factor to `week_day`.
- **`addDestination`**: Adds an airport to the `airport` table.
- **`addRoute`**: Creates a new route.
- **`addFlight`**: Sets up a weekly schedule and flight records.
- **`addReservation`**: Creates a reservation if seats are available.
- **`addPassenger`**: Adds a passenger to an existing reservation.
- **`addContact`**: Inserts contact details for a reservation passenger.
- **`addPayment`**: Adds payment details for a reservation.

### Functions

- **`calculateFreeSeats`**: Calculates available seats on a flight.
- **`calculatePrice`**: Determines the current flight price based on multiple factors.

### Trigger

- **`ticketgenerator`**: Automatically generates a ticket number after processing payment details.

### View

- **`allFlights`**: Displays a comprehensive view of all flights with detailed information, including free seats and prices.

---

## Getting Started

1. **Database Setup**: To create the schema, simply execute the SQL script provided in your SQL environment.
2. **Usage**: The procedures and functions included can be used to handle common operations, such as booking flights, adding passengers, and processing payments.

---

This schema is designed for extensibility, allowing further customization as required for specific use cases.

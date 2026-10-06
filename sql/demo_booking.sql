-- Example booking workflow. Run after schema.sql:
--   mysql flight_reservations < sql/schema.sql
--   mysql flight_reservations < sql/demo_booking.sql

CALL addYear(2010, 2.3);
CALL addYear(2011, 2.5);
CALL addDay(2010, 'Monday', 1);
CALL addDay(2011, 'Monday', 1.1);
CALL addDestination('MIT', 'Minas Tirith', 'Mordor');
CALL addDestination('HOB', 'Hobbiton', 'The Shire');
CALL addRoute('MIT', 'HOB', 2010, 2000);
CALL addRoute('MIT', 'HOB', 2011, 2000);
CALL addFlight('MIT', 'HOB', 2010, 'Monday', '09:00:00');
CALL addFlight('MIT', 'HOB', 2011, 'Monday', '09:00:00');
-- Base price = route price x weekday factor x profit factor x (booked + 1) / 40 = 2000 x 1 x 2.3 x 1/40 = 115
SELECT calculatePrice(1) AS price_before_any_booking;
CALL addReservation('MIT', 'HOB', 2010, 1, 'Monday', '09:00:00', 30, @a);
SELECT @a AS reservation_no;
CALL addPassenger(@a, 1001, 'Frodo');
CALL addPassenger(@a, 1002, 'Sam');
CALL addContact(@a, 1001, 'frodo@shire.me', 123456);
CALL addPayment(@a, 'Frodo Baggins', 4111111111111111);
SELECT COUNT(*) AS payments_recorded FROM creditcard_info;
SELECT calculateFreeSeats(1) AS free_seats_after_payment;
SELECT departure_city_name, departure_week, departure_year, nr_of_free_seats, current_price_per_seat FROM allFlights WHERE departure_week = 1;
-- A second party of 15 cannot reserve: only 10 seats remain after the first booking was paid
CALL addReservation('MIT', 'HOB', 2010, 1, 'Monday', '09:00:00', 15, @b);

-- Booking a flight that does not exist is rejected
CALL addReservation('MIT', 'HOB', 2010, 99, 'Monday', '09:00:00', 2, @c);

-- Tickets are issued on payment: reservation number + passenger sequence
SELECT passp_no, name, ticket FROM passenger WHERE res_no = @a ORDER BY passp_no;

-- Paying twice for the same reservation is rejected
CALL addPayment(@a, 'Frodo Baggins', 4111111111111111);

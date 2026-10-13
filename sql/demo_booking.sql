-- =============================================================================
-- demo_booking.sql — a guided tour of the booking workflow. Run on a freshly
-- loaded schema:
--
--   scripts/load-schema.sh mysql flight_reservations
--   mysql -t flight_reservations < sql/demo_booking.sql
-- =============================================================================

SET NAMES utf8mb4;

-- Prints why the database rejects a statement instead of stopping the script
DROP PROCEDURE IF EXISTS demo_expect_rejection;
DELIMITER //
CREATE PROCEDURE demo_expect_rejection(IN stmt TEXT)
BEGIN
    DECLARE v_errno INT DEFAULT 0;
    DECLARE v_message TEXT;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_message = MESSAGE_TEXT;
        SET @demo_sql = stmt;
        PREPARE demo_stmt FROM @demo_sql;
        EXECUTE demo_stmt;
    END;
    DEALLOCATE PREPARE demo_stmt;
    SELECT stmt AS attempted,
           IF(v_errno = 0, 'accepted (unexpected!)', CONCAT('rejected ', v_errno, ': ', v_message)) AS outcome;
END //
DELIMITER ;

-- 1. Reference data: next year's pricing factors, two airports, an aircraft,
--    a route and a weekly departure (52 dated flights)
SET @y = YEAR(CURDATE()) + 1;
CALL addYear(@y, 2.3);
CALL addDay(@y, 'Monday', 1);
CALL addDay(@y, 'Friday', 1.5);
CALL addDestination('MIT', 'Minas Tirith', 'Gondor');
CALL addDestination('HOB', 'Hobbiton', 'The Shire');
CALL addAircraft('EGL4', 'Great Eagle', 2, 2);
CALL addRoute('MIT', 'HOB', @y, 50);
CALL addFlight('MIT', 'HOB', @y, 'Monday', '09:00:00');
CALL addFlightWithAircraft('MIT', 'HOB', @y, 'Friday', '17:30:00', 'EGL4');

SELECT departure_date, departure_time, weekday, aircraft_code, free_seats, price_per_seat
FROM v_flight_availability
WHERE week = 10
ORDER BY departs_at;

-- 2. Reserve four seats on the Monday flight in week 10
SET @flight = (SELECT flight_id FROM v_flight_availability WHERE week = 10 AND weekday = 'Monday');
CALL createReservation(@flight, 4, @res, @ref);
SELECT @res AS reservation_no, @ref AS booking_reference;

-- 3. Name the passengers and the contact person
CALL addPassenger(@res, 'P-FRODO', 'Frodo Baggins');
CALL addPassenger(@res, 'P-SAM', 'Samwise Gamgee');
CALL addPassenger(@res, 'P-MERRY', 'Meriadoc Brandybuck');
CALL demo_expect_rejection("CALL addPayment(@res, 'Frodo Baggins', '4111111111111111')");
CALL addPassenger(@res, 'P-PIPPIN', 'Peregrin Took');
CALL demo_expect_rejection("CALL addPassenger(@res, 'P-GANDALF', 'Gandalf')");
CALL addContact(@res, 'P-FRODO', 'frodo@shire.me', '+46 70 123 4567');

-- 4. Pay. The fare is the current price x 4 passengers; tickets are issued
--    and the price of the remaining seats goes up.
CALL demo_expect_rejection("CALL addPayment(@res, 'Frodo Baggins', '4111111111111112')");
CALL addPayment(@res, 'Frodo Baggins', '4111 1111 1111 1111');

SELECT booking_ref, status, amount_paid, card_brand, card_last4 FROM v_booking WHERE res_no = @res;
SELECT passp_no, name, ticket FROM v_booking_passengers WHERE res_no = @res ORDER BY ticket;
SELECT free_seats, price_per_seat AS new_price_per_seat FROM v_flight_availability WHERE flight_id = @flight;
CALL demo_expect_rejection("CALL addPayment(@res, 'Frodo Baggins', '4111111111111111')");

-- 5. Choose seats
CALL assignSeat(@res, 'P-FRODO', '1A');
CALL assignSeat(@res, 'P-SAM', '1B');
CALL demo_expect_rejection("CALL assignSeat(@res, 'P-MERRY', '1A')");
CALL demo_expect_rejection("CALL assignSeat(@res, 'P-MERRY', '14F')");
SELECT name, seat_no FROM v_booking_passengers WHERE res_no = @res ORDER BY seat_no IS NULL, seat_no;

-- 6. The Great Eagle seats four: a party of three pays first, so a party of
--    two can reserve (pending bookings hold no seats) but cannot pay.
SET @eagle = (SELECT flight_id FROM v_flight_availability WHERE week = 10 AND weekday = 'Friday');
CALL createReservation(@eagle, 3, @fellowship, @fellowship_ref);
CALL addPassenger(@fellowship, 'P-ARAGORN', 'Aragorn');
CALL addPassenger(@fellowship, 'P-LEGOLAS', 'Legolas');
CALL addPassenger(@fellowship, 'P-GIMLI', 'Gimli');
CALL addContact(@fellowship, 'P-ARAGORN', 'aragorn@gondor.me', '555 0100');
CALL createReservation(@eagle, 2, @late, @late_ref);
CALL addPassenger(@late, 'P-BOROMIR', 'Boromir');
CALL addPassenger(@late, 'P-FARAMIR', 'Faramir');
CALL addContact(@late, 'P-BOROMIR', 'boromir@gondor.me', '555 0101');
CALL addPayment(@fellowship, 'Aragorn', '5555 5555 5555 4444');
CALL demo_expect_rejection("CALL addPayment(@late, 'Boromir', '4111111111111111')");

-- 7. Cancel the hobbits' booking: refunded in full (more than 30 days ahead),
--    seats and seat assignments released
CALL cancelReservation(@res, @refund);
SELECT @refund AS refunded, status, free_seats
FROM v_booking JOIN v_flight_availability USING (flight_id)
WHERE res_no = @res;

-- 8. What the database recorded, and what the business sees
SELECT table_name, record_id, action, old_data, new_data FROM audit_log ORDER BY audit_id;
SELECT departure_airport, arrival_airport, seats_sold, gross_revenue, refunds, net_revenue, revenue_rank
FROM v_route_performance;
SELECT * FROM v_booking_funnel;

DROP PROCEDURE demo_expect_rejection;

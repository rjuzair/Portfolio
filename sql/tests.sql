-- Assertions for the booking workflow. Run after schema.sql and demo_booking.sql:
--   mysql flight_reservations < sql/tests.sql
-- Any failed assertion raises an error (SQLSTATE 45000) and stops the script.

DROP PROCEDURE IF EXISTS assert_true;
DELIMITER //
CREATE PROCEDURE assert_true(IN passed BOOLEAN, IN description VARCHAR(200))
BEGIN
    IF passed IS NULL OR NOT passed THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = description;
    END IF;
END //
DELIMITER ;

CALL assert_true((SELECT COUNT(*) FROM flights_info) = 104,
                 'addFlight creates 52 weekly flights per schedule');
CALL assert_true((SELECT COUNT(*) FROM creditcard_info) = 1,
                 'a 30-seat booking on an empty 40-seat flight can be paid');
CALL assert_true(calculateFreeSeats(1) = 10,
                 'paid seats are subtracted from capacity');
CALL assert_true((SELECT amount FROM creditcard_info WHERE res_no = 1) = 3450,
                 'payment charges seat price x passengers (115 x 30)');
CALL assert_true(ABS(calculatePrice(53) - 137.5) < 0.000001,
                 '2011 flights use the 2011 weekday factor');
CALL assert_true((SELECT COUNT(*) FROM reservation) = 1,
                 'oversized and non-existent-flight reservations are rejected');
CALL assert_true((SELECT COUNT(DISTINCT ticket) FROM passenger WHERE ticket IS NOT NULL) = 2,
                 'every paid passenger gets a unique ticket number');

DROP PROCEDURE assert_true;
SELECT 'All flight reservation tests passed' AS result;

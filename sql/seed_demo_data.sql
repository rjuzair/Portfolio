-- =============================================================================
-- seed_demo_data.sql — a realistic dataset for the API, the web UI and the
-- analytics views. Run on a freshly loaded schema:
--
--   scripts/load-schema.sh mysql flight_reservations
--   mysql flight_reservations < sql/seed_demo_data.sql
--
-- Creates a European route network for this year and next, then books flights
-- through the real procedures (createReservation → addPassenger → addContact
-- → addPayment → assignSeat / cancelReservation), so every seeded row obeys
-- the same rules as production traffic. Takes about half a minute.
-- =============================================================================

SET NAMES utf8mb4;

DROP PROCEDURE IF EXISTS seed_route_pair;
DROP PROCEDURE IF EXISTS seed_one_booking;
DROP PROCEDURE IF EXISTS seed_bookings;

DELIMITER //

-- Both directions of a route for this year and next, each with weekly
-- departures given as 'Monday 07:10|Friday 17:45'. The return leg leaves
-- four hours after the outbound one.
CREATE PROCEDURE seed_route_pair(IN p_a CHAR(3), IN p_b CHAR(3), IN p_base DECIMAL(10,2),
                                 IN p_aircraft VARCHAR(10), IN p_departures VARCHAR(255))
BEGIN
    DECLARE v_year INT DEFAULT YEAR(CURDATE());
    DECLARE v_i INT;
    DECLARE v_slot VARCHAR(32);
    DECLARE v_day VARCHAR(10);
    DECLARE v_time TIME;
    DECLARE v_slots INT DEFAULT 1 + CHAR_LENGTH(p_departures) - CHAR_LENGTH(REPLACE(p_departures, '|', ''));

    WHILE v_year <= YEAR(CURDATE()) + 1 DO
        CALL addRoute(p_a, p_b, v_year, p_base);
        CALL addRoute(p_b, p_a, v_year, p_base);
        SET v_i = 1;
        WHILE v_i <= v_slots DO
            SET v_slot = SUBSTRING_INDEX(SUBSTRING_INDEX(p_departures, '|', v_i), '|', -1);
            SET v_day  = SUBSTRING_INDEX(v_slot, ' ', 1);
            SET v_time = CAST(SUBSTRING_INDEX(v_slot, ' ', -1) AS TIME);
            CALL addFlightWithAircraft(p_a, p_b, v_year, v_day, v_time, p_aircraft);
            CALL addFlightWithAircraft(p_b, p_a, v_year, v_day,
                                       SEC_TO_TIME((TIME_TO_SEC(v_time) + 4 * 3600) % 86400), p_aircraft);
            SET v_i = v_i + 1;
        END WHILE;
        SET v_year = v_year + 1;
    END WHILE;
END //

-- One booking attempt for a random party. Rejections (for example a flight
-- that filled up) are skipped, exactly as a real client would see them.
CREATE PROCEDURE seed_one_booking(IN p_flight_id INT)
BEGIN
    DECLARE v_party INT;
    DECLARE v_res INT;
    DECLARE v_ref CHAR(6);
    DECLARE v_i INT DEFAULT 1;
    DECLARE v_first VARCHAR(30);
    DECLARE v_last VARCHAR(30);
    DECLARE v_lead_first VARCHAR(30);
    DECLARE v_lead_last VARCHAR(30);
    DECLARE v_passport VARCHAR(20);
    DECLARE v_lead_passport VARCHAR(20);
    DECLARE v_rows INT;
    DECLARE v_width INT;
    DECLARE v_outcome DOUBLE DEFAULT RAND();
    DECLARE v_party_roll DOUBLE DEFAULT RAND();
    DECLARE v_refund DECIMAL(10,2);
    DECLARE v_failed INT DEFAULT 0;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_failed = 1;

    SET v_party = CASE
        WHEN v_party_roll < 0.40 THEN 1
        WHEN v_party_roll < 0.75 THEN 2
        WHEN v_party_roll < 0.87 THEN 3
        WHEN v_party_roll < 0.97 THEN 4
        ELSE 6
    END;

    CALL createReservation(p_flight_id, v_party, v_res, v_ref);
    IF v_failed = 1 OR v_res IS NULL THEN
        SET v_failed = 1;
    END IF;

    WHILE v_failed = 0 AND v_i <= v_party DO
        SET v_first = ELT(1 + FLOOR(RAND() * 40),
            'Anna', 'Erik', 'Maja', 'Lars', 'Sofia', 'Johan', 'Emma', 'Oskar', 'Ingrid', 'Nils',
            'Freja', 'Mikael', 'Aino', 'Mateo', 'Lucia', 'Pierre', 'Camille', 'Hugo', 'Chloe', 'Lukas',
            'Mia', 'Jonas', 'Lea', 'Marco', 'Giulia', 'Pablo', 'Elena', 'Sean', 'Aoife', 'Daan',
            'Fleur', 'Amir', 'Leila', 'Yusuf', 'Hana', 'Kenji', 'Priya', 'Arjun', 'Grace', 'Noah');
        SET v_last = ELT(1 + FLOOR(RAND() * 40),
            'Andersson', 'Johansson', 'Karlsson', 'Nilsson', 'Eriksson', 'Larsen', 'Hansen', 'Virtanen',
            'Korhonen', 'Jensen', 'Muller', 'Schmidt', 'Weber', 'Martin', 'Bernard', 'Dubois', 'Rossi',
            'Russo', 'Garcia', 'Fernandez', 'Lopez', 'Murphy', 'Kelly', 'de Vries', 'Jansen', 'Smith',
            'Jones', 'Brown', 'Taylor', 'Wilson', 'Novak', 'Kowalski', 'Horvat', 'Papadopoulos',
            'Silva', 'Costa', 'Haddad', 'Sato', 'Patel', 'Okafor');
        SET v_passport = CONCAT(CHAR(65 + FLOOR(RAND() * 26)), CHAR(65 + FLOOR(RAND() * 26)),
                                LPAD(FLOOR(RAND() * 10000000), 7, '0'));
        IF v_i = 1 THEN
            SET v_lead_first = v_first, v_lead_last = v_last, v_lead_passport = v_passport;
        ELSE
            SET v_last = v_lead_last;     -- travel parties are mostly families
        END IF;
        CALL addPassenger(v_res, v_passport, CONCAT(v_first, ' ', v_last));
        SET v_i = v_i + 1;
    END WHILE;

    IF v_failed = 0 THEN
        CALL addContact(v_res, v_lead_passport,
                        LOWER(CONCAT(v_lead_first, '.', REPLACE(v_lead_last, ' ', ''), '@example.com')),
                        CONCAT('+46 7', FLOOR(RAND() * 10), ' ', LPAD(FLOOR(RAND() * 10000000), 7, '0')));
    END IF;

    -- 86 % pay, 8 % abandon the checkout recently, 6 % abandoned long ago
    IF v_failed = 0 AND v_outcome < 0.86 THEN
        CALL addPayment(v_res, CONCAT(v_lead_first, ' ', v_lead_last),
                        ELT(1 + FLOOR(RAND() * 4), '4111111111111111', '5555555555554444',
                                                   '378282246310005', '6011111111111117'));
        -- about half of the paying parties pick seats
        IF v_failed = 0 AND RAND() < 0.5 THEN
            SELECT a.seat_rows, a.seats_per_row INTO v_rows, v_width
            FROM flights_info fi
            JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
            JOIN aircraft a         ON a.aircraft_code = ws.aircraft_code
            WHERE fi.flight_id = p_flight_id;
            SET v_i = 0;
            WHILE v_i < v_party DO
                SELECT passp_no INTO v_passport FROM passenger
                WHERE res_no = v_res ORDER BY passp_no LIMIT 1 OFFSET v_i;
                -- a taken seat is simply skipped (the handler swallows 7104)
                CALL assignSeat(v_res, v_passport,
                                CONCAT(1 + FLOOR(RAND() * v_rows),
                                       SUBSTRING('ABCDEFGHJK', 1 + FLOOR(RAND() * v_width), 1)));
                SET v_i = v_i + 1;
            END WHILE;
        END IF;
        -- a few change their plans
        IF v_failed = 0 AND RAND() < 0.05 THEN
            CALL cancelReservation(v_res, v_refund);
        END IF;
    ELSEIF v_failed = 0 AND v_outcome >= 0.94 THEN
        UPDATE reservation SET created_at = NOW() - INTERVAL 3 HOUR WHERE res_no = v_res;
    END IF;
END //

-- Books flights departing between p_from and p_to until each reaches a
-- random load factor between p_min_load and p_max_load percent
CREATE PROCEDURE seed_bookings(IN p_from DATE, IN p_to DATE, IN p_min_load INT, IN p_max_load INT)
BEGIN
    DECLARE v_flight INT DEFAULT 0;
    DECLARE v_capacity INT;
    DECLARE v_target INT;
    DECLARE v_attempts INT;

    flights: LOOP
        SET v_capacity = NULL;
        SELECT flight_id, capacity INTO v_flight, v_capacity
        FROM flights_info
        WHERE flight_id > v_flight
          AND departure_date BETWEEN GREATEST(p_from, CURDATE() + INTERVAL 1 DAY) AND p_to
        ORDER BY flight_id
        LIMIT 1;
        IF v_capacity IS NULL THEN
            LEAVE flights;
        END IF;

        SET v_target = FLOOR(v_capacity * (p_min_load + RAND() * (p_max_load - p_min_load)) / 100);
        SET v_attempts = 0;
        WHILE bookedSeats(v_flight) < v_target AND v_attempts < v_capacity DO
            CALL seed_one_booking(v_flight);
            SET v_attempts = v_attempts + 1;
        END WHILE;
    END LOOP;
END //

DELIMITER ;

-- ---------------------------------------------------------------------------
-- Pricing calendar: profit factor per year, demand factor per weekday
-- ---------------------------------------------------------------------------
SET @y0 = YEAR(CURDATE());
CALL addYear(@y0, 1.00);
CALL addYear(@y0 + 1, 1.04);
CALL addDay(@y0, 'Monday', 1.10);    CALL addDay(@y0 + 1, 'Monday', 1.10);
CALL addDay(@y0, 'Tuesday', 0.90);   CALL addDay(@y0 + 1, 'Tuesday', 0.90);
CALL addDay(@y0, 'Wednesday', 0.90); CALL addDay(@y0 + 1, 'Wednesday', 0.90);
CALL addDay(@y0, 'Thursday', 1.00);  CALL addDay(@y0 + 1, 'Thursday', 1.00);
CALL addDay(@y0, 'Friday', 1.30);    CALL addDay(@y0 + 1, 'Friday', 1.30);
CALL addDay(@y0, 'Saturday', 0.85);  CALL addDay(@y0 + 1, 'Saturday', 0.85);
CALL addDay(@y0, 'Sunday', 1.20);    CALL addDay(@y0 + 1, 'Sunday', 1.20);

-- ---------------------------------------------------------------------------
-- Airports and fleet
-- ---------------------------------------------------------------------------
CALL addDestination('ARN', 'Stockholm Arlanda', 'Sweden');
CALL addDestination('GOT', 'Gothenburg Landvetter', 'Sweden');
CALL addDestination('CPH', 'Copenhagen Kastrup', 'Denmark');
CALL addDestination('OSL', 'Oslo Gardermoen', 'Norway');
CALL addDestination('HEL', 'Helsinki-Vantaa', 'Finland');
CALL addDestination('LHR', 'London Heathrow', 'United Kingdom');
CALL addDestination('CDG', 'Paris Charles de Gaulle', 'France');
CALL addDestination('AMS', 'Amsterdam Schiphol', 'Netherlands');
CALL addDestination('FRA', 'Frankfurt am Main', 'Germany');
CALL addDestination('BCN', 'Barcelona El Prat', 'Spain');
CALL addDestination('FCO', 'Rome Fiumicino', 'Italy');
CALL addDestination('JFK', 'New York John F. Kennedy', 'United States');

CALL addAircraft('A320', 'Airbus A320neo', 30, 6);
CALL addAircraft('E190', 'Embraer E190', 25, 4);
CALL addAircraft('AT76', 'ATR 72-600', 18, 4);
CALL addAircraft('B789', 'Boeing 787-9', 32, 9);

-- ---------------------------------------------------------------------------
-- Route network: Stockholm hub plus a few point-to-point routes
-- ---------------------------------------------------------------------------
CALL seed_route_pair('ARN', 'GOT', 55.00, 'AT76', 'Monday 06:45|Wednesday 06:45|Friday 16:30|Sunday 18:00');
CALL seed_route_pair('ARN', 'CPH', 70.00, 'E190', 'Monday 07:10|Thursday 12:20|Friday 17:05');
CALL seed_route_pair('ARN', 'OSL', 65.00, 'E190', 'Tuesday 08:00|Friday 15:40|Sunday 19:15');
CALL seed_route_pair('ARN', 'HEL', 60.00, 'AT76', 'Monday 08:30|Wednesday 13:10|Saturday 10:00');
CALL seed_route_pair('ARN', 'LHR', 95.00, 'A320', 'Monday 06:55|Wednesday 11:40|Friday 17:20|Sunday 15:00');
CALL seed_route_pair('ARN', 'CDG', 90.00, 'A320', 'Tuesday 07:25|Thursday 13:05|Saturday 09:45');
CALL seed_route_pair('ARN', 'AMS', 85.00, 'A320', 'Monday 09:10|Friday 14:30');
CALL seed_route_pair('ARN', 'FRA', 85.00, 'A320', 'Wednesday 07:05|Sunday 16:50');
CALL seed_route_pair('ARN', 'BCN', 110.00, 'A320', 'Saturday 08:15|Tuesday 10:30');
CALL seed_route_pair('ARN', 'FCO', 115.00, 'A320', 'Thursday 09:20|Sunday 11:00');
CALL seed_route_pair('ARN', 'JFK', 360.00, 'B789', 'Monday 10:40|Thursday 10:40|Saturday 12:15');
CALL seed_route_pair('CPH', 'LHR', 80.00, 'E190', 'Tuesday 07:45|Friday 18:10');
CALL seed_route_pair('OSL', 'AMS', 80.00, 'E190', 'Wednesday 08:50|Sunday 17:30');
CALL seed_route_pair('LHR', 'JFK', 340.00, 'B789', 'Tuesday 11:15|Friday 11:15');

-- ---------------------------------------------------------------------------
-- Bookings: a busy next week, then a thinning forward-booking curve
-- ---------------------------------------------------------------------------
-- Bulk load: every booking step commits, so stop flushing the redo log and
-- binary log to disk on each commit while seeding (restored below)
SET @saved_flush = @@GLOBAL.innodb_flush_log_at_trx_commit, @saved_sync_binlog = @@GLOBAL.sync_binlog;
SET GLOBAL innodb_flush_log_at_trx_commit = 2, GLOBAL sync_binlog = 0;

CALL seed_bookings(CURDATE(), CURDATE() + INTERVAL 7 DAY, 35, 92);
CALL seed_bookings(CURDATE() + INTERVAL 8 DAY, CURDATE() + INTERVAL 28 DAY, 10, 32);
CALL seed_bookings(CURDATE() + INTERVAL 29 DAY, CURDATE() + INTERVAL 90 DAY, 1, 6);
CALL seed_bookings(CURDATE() + INTERVAL 91 DAY, CURDATE() + INTERVAL 180 DAY, 0, 2);

SET GLOBAL innodb_flush_log_at_trx_commit = @saved_flush, GLOBAL sync_binlog = @saved_sync_binlog;

-- Abandoned checkouts from "hours ago" expire, as the scheduled job would do
CALL expirePendingReservations(30, @expired);

DROP PROCEDURE seed_route_pair;
DROP PROCEDURE seed_one_booking;
DROP PROCEDURE seed_bookings;

SELECT (SELECT COUNT(*) FROM airport)                         AS airports,
       (SELECT COUNT(*) FROM route)                           AS routes,
       (SELECT COUNT(*) FROM flights_info)                    AS flights,
       (SELECT COUNT(*) FROM reservation)                     AS reservations,
       (SELECT COUNT(*) FROM passenger WHERE ticket IS NOT NULL) AS tickets,
       (SELECT COUNT(*) FROM seat_assignment)                 AS seats_assigned,
       (SELECT SUM(amount - refunded_amount) FROM payment)    AS net_revenue;

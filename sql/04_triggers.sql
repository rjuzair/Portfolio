-- =============================================================================
-- 04_triggers.sql — invariants and side effects the database enforces itself
-- =============================================================================

SET NAMES utf8mb4;

DROP TRIGGER IF EXISTS ticketgenerator;
DROP TRIGGER IF EXISTS trg_reservation_status_guard;
DROP TRIGGER IF EXISTS trg_reservation_inventory;
DROP TRIGGER IF EXISTS trg_reservation_audit_insert;
DROP TRIGGER IF EXISTS trg_payment_guard;
DROP TRIGGER IF EXISTS trg_payment_audit_insert;
DROP TRIGGER IF EXISTS trg_payment_audit_update;
DROP TRIGGER IF EXISTS trg_seat_audit_insert;
DROP TRIGGER IF EXISTS trg_seat_audit_delete;

DELIMITER //

-- Issues ticket numbers once a reservation is paid:
-- reservation number followed by a three-digit passenger sequence, so tickets
-- are unique by construction.
CREATE TRIGGER ticketgenerator
AFTER INSERT ON payment
FOR EACH ROW
BEGIN
    UPDATE passenger p
    JOIN (
        SELECT passp_no, ROW_NUMBER() OVER (ORDER BY passp_no) AS seq
        FROM passenger
        WHERE res_no = NEW.res_no
    ) numbered ON numbered.passp_no = p.passp_no
    SET p.ticket = NEW.res_no * 1000 + numbered.seq
    WHERE p.res_no = NEW.res_no;
END //

-- Reservation state machine. Only these transitions are legal, whichever
-- account or code path issues the UPDATE:
--   PENDING   → CONFIRMED | CANCELLED | EXPIRED
--   CONFIRMED → CANCELLED
CREATE TRIGGER trg_reservation_status_guard
BEFORE UPDATE ON reservation
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'PENDING'   AND NEW.status IN ('CONFIRMED', 'CANCELLED', 'EXPIRED'))
        OR (OLD.status = 'CONFIRMED' AND NEW.status = 'CANCELLED')) THEN
        SIGNAL SQLSTATE '45000'
            SET MYSQL_ERRNO = 7109, MESSAGE_TEXT = 'Illegal reservation status transition';
    END IF;
    IF NEW.flight_id <> OLD.flight_id OR NEW.no_passengers <> OLD.no_passengers
       OR NEW.booking_ref <> OLD.booking_ref THEN
        SIGNAL SQLSTATE '45000'
            SET MYSQL_ERRNO = 7110, MESSAGE_TEXT = 'A reservation''s flight, size and reference cannot change';
    END IF;
END //

-- Keeps flights_info.seats_booked equal to the passengers on CONFIRMED
-- reservations. chk_flight_inventory rejects the update if it would oversell.
CREATE TRIGGER trg_reservation_inventory
AFTER UPDATE ON reservation
FOR EACH ROW
BEGIN
    IF NEW.status = 'CONFIRMED' AND OLD.status <> 'CONFIRMED' THEN
        UPDATE flights_info SET seats_booked = seats_booked + NEW.no_passengers
        WHERE flight_id = NEW.flight_id;
    ELSEIF OLD.status = 'CONFIRMED' AND NEW.status <> 'CONFIRMED' THEN
        UPDATE flights_info SET seats_booked = seats_booked - OLD.no_passengers
        WHERE flight_id = OLD.flight_id;
    END IF;

    IF NEW.status <> OLD.status THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES ('reservation', NEW.res_no, 'UPDATE',
                JSON_OBJECT('status', OLD.status),
                JSON_OBJECT('status', NEW.status),
                USER());
    END IF;
END //

CREATE TRIGGER trg_reservation_audit_insert
AFTER INSERT ON reservation
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
    VALUES ('reservation', NEW.res_no, 'INSERT',
            JSON_OBJECT('booking_ref', NEW.booking_ref, 'flight_id', NEW.flight_id,
                        'no_passengers', NEW.no_passengers, 'status', NEW.status),
            USER());
END //

-- A captured amount never changes; refunds may only grow
CREATE TRIGGER trg_payment_guard
BEFORE UPDATE ON payment
FOR EACH ROW
BEGIN
    IF NEW.amount <> OLD.amount OR NEW.res_no <> OLD.res_no
       OR NEW.refunded_amount < OLD.refunded_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MYSQL_ERRNO = 7111, MESSAGE_TEXT = 'A captured payment cannot be altered';
    END IF;
END //

-- Audit rows for payments carry the card brand and last four digits only
CREATE TRIGGER trg_payment_audit_insert
AFTER INSERT ON payment
FOR EACH ROW
FOLLOWS ticketgenerator
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
    VALUES ('payment', NEW.payment_id, 'INSERT',
            JSON_OBJECT('res_no', NEW.res_no, 'amount', NEW.amount,
                        'card_brand', NEW.card_brand, 'card_last4', NEW.card_last4),
            USER());
END //

CREATE TRIGGER trg_payment_audit_update
AFTER UPDATE ON payment
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
    VALUES ('payment', NEW.payment_id, 'UPDATE',
            JSON_OBJECT('refunded_amount', OLD.refunded_amount),
            JSON_OBJECT('refunded_amount', NEW.refunded_amount),
            USER());
END //

CREATE TRIGGER trg_seat_audit_insert
AFTER INSERT ON seat_assignment
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
    VALUES ('seat_assignment', CONCAT(NEW.flight_id, '/', NEW.seat_no), 'INSERT',
            JSON_OBJECT('res_no', NEW.res_no, 'passp_no', NEW.passp_no), USER());
END //

CREATE TRIGGER trg_seat_audit_delete
AFTER DELETE ON seat_assignment
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, changed_by)
    VALUES ('seat_assignment', CONCAT(OLD.flight_id, '/', OLD.seat_no), 'DELETE',
            JSON_OBJECT('res_no', OLD.res_no, 'passp_no', OLD.passp_no), USER());
END //

DELIMITER ;

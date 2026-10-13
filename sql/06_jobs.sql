-- =============================================================================
-- 06_jobs.sql — scheduled housekeeping
--
-- Needs the event scheduler (on by default in MySQL 8; MariaDB: set
-- event_scheduler=ON). Creating the event works either way.
-- =============================================================================

SET NAMES utf8mb4;

DROP EVENT IF EXISTS ev_expire_pending_reservations;

-- Unpaid reservations older than 30 minutes are abandoned checkouts
CREATE EVENT ev_expire_pending_reservations
ON SCHEDULE EVERY 5 MINUTE
COMMENT 'Expire reservations left unpaid for 30 minutes'
DO CALL expirePendingReservations(30, @expired_reservations);

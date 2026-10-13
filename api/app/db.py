"""Connection pooling and cursor handling for PyMySQL."""

import queue
from collections.abc import Iterator
from contextlib import contextmanager, suppress

import pymysql
from pymysql.cursors import DictCursor

from .config import Settings

# Errors the database raises deliberately (business rules, constraints,
# missing privileges) or that only roll back one transaction (lock wait
# timeout, deadlock). The connection is still healthy after them.
_EXPECTED_ERRNOS = {1062, 1142, 1205, 1213, 1370, 3819, 4025}


def errno_of(exc: pymysql.MySQLError) -> int | None:
    code = exc.args[0] if exc.args else None
    return code if isinstance(code, int) else None


def is_expected_error(exc: pymysql.MySQLError) -> bool:
    code = errno_of(exc)
    return code is not None and (7000 <= code < 8000 or code in _EXPECTED_ERRNOS)


class Database:
    """A small LIFO pool of autocommit connections.

    Autocommit is deliberate: the stored procedures own their transactions
    (START TRANSACTION ... COMMIT), so the API never holds one open.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._idle: queue.LifoQueue[pymysql.Connection] = queue.LifoQueue(
            maxsize=settings.db_pool_size
        )

    def _connect(self) -> pymysql.Connection:
        s = self._settings
        return pymysql.connect(
            host=s.db_host,
            port=s.db_port,
            user=s.db_user,
            password=s.db_password,
            database=s.db_name,
            charset="utf8mb4",
            autocommit=True,
            cursorclass=DictCursor,
            connect_timeout=5,
        )

    def _acquire(self) -> pymysql.Connection:
        try:
            conn = self._idle.get_nowait()
        except queue.Empty:
            return self._connect()
        try:
            conn.ping()  # the server may have closed an idle connection
        except pymysql.MySQLError:
            with suppress(pymysql.MySQLError):
                conn.close()
            conn = self._connect()
        return conn

    def _release(self, conn: pymysql.Connection) -> None:
        try:
            self._idle.put_nowait(conn)
        except queue.Full:
            conn.close()

    @contextmanager
    def cursor(self) -> Iterator[DictCursor]:
        """Borrow a connection for one unit of work.

        Closing the cursor drains any remaining result sets, so the
        connection goes back to the pool clean. A connection that failed for
        an unexpected reason is discarded instead of reused.
        """
        conn = self._acquire()
        healthy = True
        try:
            with conn.cursor() as cur:
                yield cur
        except pymysql.MySQLError as exc:
            healthy = is_expected_error(exc)
            raise
        except BaseException:
            healthy = False
            raise
        finally:
            if healthy:
                self._release(conn)
            else:
                with suppress(pymysql.MySQLError):
                    conn.close()

    def close(self) -> None:
        while True:
            try:
                conn = self._idle.get_nowait()
            except queue.Empty:
                return
            with suppress(pymysql.MySQLError):
                conn.close()

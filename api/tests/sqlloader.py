"""Run the repository's .sql files (which use the client's DELIMITER command)
through a DB-API connection, so the tests need no mysql command-line client."""

import re
from collections.abc import Iterator
from pathlib import Path

SQL_DIR = Path(__file__).resolve().parents[2] / "sql"
_COMMENT = re.compile(r"^\s*(--.*|#.*)?$")


def statements(script: str) -> Iterator[str]:
    delimiter, buffer = ";", []
    for line in script.splitlines():
        stripped = line.strip()
        if stripped.upper().startswith("DELIMITER "):
            delimiter = stripped.split(None, 1)[1]
            continue
        buffer.append(line)
        if stripped.endswith(delimiter):
            statement = "\n".join(buffer).strip()[: -len(delimiter)].strip()
            buffer = []
            if not all(_COMMENT.match(part) for part in statement.splitlines()):
                yield statement


def run_file(cursor, path: Path) -> None:
    for statement in statements(path.read_text()):
        cursor.execute(statement)
        while cursor.nextset():
            pass


def schema_modules() -> list[Path]:
    return sorted(SQL_DIR.glob("0[1-7]_*.sql"))

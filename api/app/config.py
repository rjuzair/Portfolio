from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuration from environment variables (DB_HOST, DB_PASSWORD, ...)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    db_host: str = "127.0.0.1"
    db_port: int = 3306
    db_name: str = "flight_reservations"
    # A least-privileged account holding the flight_api role (sql/07_security.sql)
    db_user: str = "booking_api"
    db_password: str = ""
    db_pool_size: int = 10
    # When set, /api/insights requires an X-API-Key header with this value
    insights_api_key: str | None = None
    log_level: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    return Settings()

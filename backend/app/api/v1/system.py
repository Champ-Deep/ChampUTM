"""System / operations endpoints.

Read-only vitals for the people who run the platform: third-party quota, spend
and the checks a health monitor needs. Accepts API keys (not just interactive
sessions) so the uptime monitor can poll it with a scoped key.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import TokenData, require_auth
from app.db.postgres import get_db_session
from app.services import maxmind_usage

router = APIRouter(prefix="/system", tags=["System"])


@router.get("/maxmind")
async def maxmind_status(
    days: int = Query(30, ge=1, le=365, description="Burn-rate window."),
    user: TokenData = Depends(require_auth),
    session: AsyncSession = Depends(get_db_session),
):
    """MaxMind GeoIP2 credit balance, burn rate, projected exhaustion and spend.

    The balance comes from MaxMind's own ``queries_remaining``, carried on every
    web-service response — it costs no extra query to read.
    """
    return await maxmind_usage.usage_summary(session, days=days)


@router.get("/status")
async def system_status(
    user: TokenData = Depends(require_auth),
    session: AsyncSession = Depends(get_db_session),
):
    """One call a health monitor can grade: database plus every metered
    dependency. ``ok`` is false when anything needs a human."""
    checks: dict[str, dict] = {}

    try:
        await session.execute(text("SELECT 1"))
        checks["database"] = {"status": "ok"}
    except Exception as exc:  # noqa: BLE001 - report, don't raise
        checks["database"] = {"status": "critical", "detail": str(exc)[:200]}

    try:
        mm = await maxmind_usage.usage_summary(session, days=30)
        checks["maxmind"] = {
            "status": mm["status"],
            "queries_remaining": mm["queries_remaining"],
            "avg_daily": mm["avg_daily"],
            "days_left": mm["days_left"],
            "projected_exhaustion": mm["projected_exhaustion"],
        }
    except Exception as exc:  # noqa: BLE001
        checks["maxmind"] = {"status": "unknown", "detail": str(exc)[:200]}

    bad = {"critical", "warning"}
    return {
        "ok": not any(c.get("status") in bad for c in checks.values()),
        "checks": checks,
    }

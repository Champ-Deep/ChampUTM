"""MaxMind web-service usage, remaining credit and spend.

Every GeoIP2 web-service response carries MaxMind's own ``queries_remaining``
counter, so the credit balance is free to observe — there is no billing API to
call and no extra request to pay for. We record it alongside our own per-day
lookup counts, which together give burn rate, projected exhaustion and spend.

Every function here fails open: geo enrichment must never break because usage
bookkeeping had a bad day.
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta
from typing import Optional

from sqlalchemy import select, text

from app.core.config import settings

logger = logging.getLogger(__name__)


async def record_lookup(*, queries_remaining: Optional[int], ok: bool) -> None:
    """Count one web-service call against today and store the latest balance.

    Called from the geo enrichment background task, which owns no session, so we
    open our own. Never raises.
    """
    try:
        from app.db.postgres import async_session_maker

        async with async_session_maker() as session:
            await session.execute(
                text(
                    """
                    INSERT INTO maxmind_usage (day, lookups, errors, queries_remaining, updated_at)
                    VALUES (:day, :ok, :err, :rem, :now)
                    ON CONFLICT (day) DO UPDATE SET
                        lookups = maxmind_usage.lookups + :ok,
                        errors  = maxmind_usage.errors  + :err,
                        queries_remaining = COALESCE(:rem, maxmind_usage.queries_remaining),
                        updated_at = :now
                    """
                ),
                {
                    "day": datetime.utcnow().date(),
                    "ok": 1 if ok else 0,
                    "err": 0 if ok else 1,
                    "rem": queries_remaining,
                    "now": datetime.utcnow(),
                },
            )
            await session.commit()
    except Exception as exc:  # noqa: BLE001 - telemetry must never break tracking
        logger.debug("MaxMind usage bookkeeping failed: %s", exc)


def _status(remaining: Optional[int]) -> str:
    if remaining is None:
        return "unknown"
    if remaining <= settings.maxmind_credit_crit_threshold:
        return "critical"
    if remaining <= settings.maxmind_credit_warn_threshold:
        return "warning"
    return "ok"


async def usage_summary(session, *, days: int = 30) -> dict:
    """Balance, burn rate, projected exhaustion and spend.

    ``days`` bounds the burn-rate window only; lifetime totals are unbounded.
    """
    from app.models.maxmind_usage import MaxMindUsage

    today = datetime.utcnow().date()
    since = today - timedelta(days=days - 1)

    rows = (
        await session.execute(
            select(MaxMindUsage).where(MaxMindUsage.day >= since).order_by(MaxMindUsage.day)
        )
    ).scalars().all()

    latest = (
        await session.execute(
            select(MaxMindUsage)
            .where(MaxMindUsage.queries_remaining.isnot(None))
            .order_by(MaxMindUsage.updated_at.desc())
            .limit(1)
        )
    ).scalars().first()

    lifetime = (
        await session.execute(text("SELECT COALESCE(SUM(lookups),0), COALESCE(SUM(errors),0) FROM maxmind_usage"))
    ).one()

    window_lookups = sum(r.lookups for r in rows)
    today_lookups = next((r.lookups for r in rows if r.day == today), 0)

    # Average over days actually observed, not the whole window — a service
    # switched on last week must not look like it burns 1/30th of its real rate.
    observed_days = max(1, len({r.day for r in rows if r.lookups}))
    avg_daily = window_lookups / observed_days if window_lookups else 0.0

    remaining = latest.queries_remaining if latest else None
    days_left = int(remaining / avg_daily) if remaining is not None and avg_daily > 0 else None
    exhaustion = (today + timedelta(days=days_left)).isoformat() if days_left is not None else None

    price = settings.maxmind_unit_price_usd or 0.0
    return {
        "configured": settings.maxmind_ws_configured,
        "endpoint": settings.maxmind_ws_endpoint,
        "queries_remaining": remaining,
        "balance_as_of": latest.updated_at.isoformat() + "Z" if latest else None,
        "status": _status(remaining),
        "warn_threshold": settings.maxmind_credit_warn_threshold,
        "critical_threshold": settings.maxmind_credit_crit_threshold,
        "lookups_today": today_lookups,
        "lookups_window": window_lookups,
        "window_days": days,
        "errors_window": sum(r.errors for r in rows),
        "avg_daily": round(avg_daily, 1),
        "days_left": days_left,
        "projected_exhaustion": exhaustion,
        "lifetime_lookups": int(lifetime[0]),
        "lifetime_errors": int(lifetime[1]),
        "unit_price_usd": price,
        "spend_window_usd": round(window_lookups * price, 2) if price else None,
        "spend_lifetime_usd": round(int(lifetime[0]) * price, 2) if price else None,
        "daily": [
            {"day": r.day.isoformat(), "lookups": r.lookups, "errors": r.errors,
             "queries_remaining": r.queries_remaining}
            for r in rows
        ],
    }

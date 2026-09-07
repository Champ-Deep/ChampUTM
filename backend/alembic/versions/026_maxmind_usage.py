"""MaxMind GeoIP2 web-service usage + credit ledger.

One row per UTC day. ``queries_remaining`` is MaxMind's own authoritative
counter, returned in the ``maxmind`` object of every Insights/City response —
so tracking costs nothing extra, no billing API call is needed.

Idempotent via IF NOT EXISTS, matching the defensive style of prior migrations.

Revision ID: 026_maxmind_usage
Revises: 025_beam_state
"""

from alembic import op


revision = "026_maxmind_usage"
down_revision = "025_beam_state"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS maxmind_usage (
            day DATE PRIMARY KEY,
            lookups INTEGER NOT NULL DEFAULT 0,
            errors INTEGER NOT NULL DEFAULT 0,
            queries_remaining INTEGER,
            updated_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS idx_maxmind_usage_day ON maxmind_usage (day DESC)")


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS maxmind_usage")

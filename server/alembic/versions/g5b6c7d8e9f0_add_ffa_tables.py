"""add ffa_matches and ffa_rounds tables

Revision ID: g5b6c7d8e9f0
Revises: f4a5b6c7d8e9
Create Date: 2026-05-18
"""
from alembic import op
import sqlalchemy as sa

revision = 'g5b6c7d8e9f0'
down_revision = 'f4a5b6c7d8e9'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "ffa_matches",
        sa.Column("id", sa.String(16), primary_key=True),
        sa.Column("p1_id", sa.String(16), sa.ForeignKey("players.id"), nullable=False),
        sa.Column("p2_id", sa.String(16), sa.ForeignKey("players.id"), nullable=False),
        sa.Column("p3_id", sa.String(16), sa.ForeignKey("players.id"), nullable=False),
        sa.Column("p4_id", sa.String(16), sa.ForeignKey("players.id"), nullable=False),
        sa.Column("p1_username", sa.String(32), nullable=False),
        sa.Column("p2_username", sa.String(32), nullable=False),
        sa.Column("p3_username", sa.String(32), nullable=False),
        sa.Column("p4_username", sa.String(32), nullable=False),
        sa.Column("p1_score", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p2_score", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p3_score", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p4_score", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p1_placement", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p2_placement", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p3_placement", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("p4_placement", sa.Integer(), default=0, nullable=False, server_default="0"),
        sa.Column("winner_id", sa.String(16), sa.ForeignKey("players.id"), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )

    op.create_table(
        "ffa_rounds",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("match_id", sa.String(16), sa.ForeignKey("ffa_matches.id", ondelete="CASCADE"), nullable=False),
        sa.Column("round_num", sa.Integer(), nullable=False),
        sa.Column("t_stimulus_us", sa.BigInteger(), nullable=False),
        sa.Column("delay_s", sa.Float(), nullable=False),
        sa.Column("p1_rt_ms", sa.Float(), nullable=True),
        sa.Column("p2_rt_ms", sa.Float(), nullable=True),
        sa.Column("p3_rt_ms", sa.Float(), nullable=True),
        sa.Column("p4_rt_ms", sa.Float(), nullable=True),
        sa.Column("p1_rt_raw_ms", sa.Float(), nullable=True),
        sa.Column("p2_rt_raw_ms", sa.Float(), nullable=True),
        sa.Column("p3_rt_raw_ms", sa.Float(), nullable=True),
        sa.Column("p4_rt_raw_ms", sa.Float(), nullable=True),
        sa.Column("p1_pre_click", sa.Boolean(), default=False, server_default="false"),
        sa.Column("p2_pre_click", sa.Boolean(), default=False, server_default="false"),
        sa.Column("p3_pre_click", sa.Boolean(), default=False, server_default="false"),
        sa.Column("p4_pre_click", sa.Boolean(), default=False, server_default="false"),
        sa.Column("p1_rtt_ms", sa.Float(), nullable=True),
        sa.Column("p2_rtt_ms", sa.Float(), nullable=True),
        sa.Column("p3_rtt_ms", sa.Float(), nullable=True),
        sa.Column("p4_rtt_ms", sa.Float(), nullable=True),
        sa.Column("winner_slot", sa.Integer(), default=0, server_default="0"),
    )


def downgrade() -> None:
    op.drop_table("ffa_rounds")
    op.drop_table("ffa_matches")

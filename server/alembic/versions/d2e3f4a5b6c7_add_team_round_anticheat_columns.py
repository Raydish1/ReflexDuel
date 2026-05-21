"""add team_round anticheat columns

Revision ID: d2e3f4a5b6c7
Revises: c1d2e3f4a5b6
Create Date: 2026-05-13
"""
from alembic import op
import sqlalchemy as sa

revision = 'd2e3f4a5b6c7'
down_revision = 'c1d2e3f4a5b6'
branch_labels = None
depends_on = None


def upgrade() -> None:
    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        op.add_column("team_rounds", sa.Column(f"{prefix}_rt_raw_ms", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_client_rt_ms", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_rtt_ms", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_click_duration_ms", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_mouse_distance_5s_px", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_time_since_mouse_move_ms", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_window_focused", sa.Boolean(), nullable=True))


def downgrade() -> None:
    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        for suffix in ["rt_raw_ms", "client_rt_ms", "rtt_ms", "click_duration_ms",
                       "mouse_distance_5s_px", "time_since_mouse_move_ms", "window_focused"]:
            op.drop_column("team_rounds", f"{prefix}_{suffix}")

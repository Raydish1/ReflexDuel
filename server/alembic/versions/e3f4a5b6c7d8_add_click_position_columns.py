"""add click position columns to rounds and team_rounds

Revision ID: e3f4a5b6c7d8
Revises: d2e3f4a5b6c7
Create Date: 2026-05-13
"""
from alembic import op
import sqlalchemy as sa

revision = 'e3f4a5b6c7d8'
down_revision = 'd2e3f4a5b6c7'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1v1 rounds table
    for prefix in ["p1", "p2"]:
        op.add_column("rounds", sa.Column(f"{prefix}_click_pos_x", sa.Float(), nullable=True))
        op.add_column("rounds", sa.Column(f"{prefix}_click_pos_y", sa.Float(), nullable=True))

    # 2v2 team_rounds table
    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        op.add_column("team_rounds", sa.Column(f"{prefix}_click_pos_x", sa.Float(), nullable=True))
        op.add_column("team_rounds", sa.Column(f"{prefix}_click_pos_y", sa.Float(), nullable=True))


def downgrade() -> None:
    for prefix in ["p1", "p2"]:
        op.drop_column("rounds", f"{prefix}_click_pos_x")
        op.drop_column("rounds", f"{prefix}_click_pos_y")

    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        op.drop_column("team_rounds", f"{prefix}_click_pos_x")
        op.drop_column("team_rounds", f"{prefix}_click_pos_y")

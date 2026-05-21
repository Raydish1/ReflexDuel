"""add pre_click_displacement_px columns

Revision ID: f4a5b6c7d8e9
Revises: e3f4a5b6c7d8
Create Date: 2026-05-13
"""
from alembic import op
import sqlalchemy as sa

revision = 'f4a5b6c7d8e9'
down_revision = 'e3f4a5b6c7d8'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("rounds", sa.Column("p1_pre_click_displacement_px", sa.Float(), nullable=True))
    op.add_column("rounds", sa.Column("p2_pre_click_displacement_px", sa.Float(), nullable=True))

    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        op.add_column("team_rounds", sa.Column(f"{prefix}_pre_click_displacement_px", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("rounds", "p1_pre_click_displacement_px")
    op.drop_column("rounds", "p2_pre_click_displacement_px")

    for prefix in ["t1_p1", "t1_p2", "t2_p1", "t2_p2"]:
        op.drop_column("team_rounds", f"{prefix}_pre_click_displacement_px")

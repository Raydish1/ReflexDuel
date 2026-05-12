"""add_match_avg_rt_columns

Revision ID: a1b2c3d4e5f6
Revises: 761ccac19331
Create Date: 2026-05-12 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a1b2c3d4e5f6'
down_revision: Union[str, Sequence[str], None] = '761ccac19331'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('matches', sa.Column('p1_avg_rt_ms', sa.Float(), nullable=True))
    op.add_column('matches', sa.Column('p2_avg_rt_ms', sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column('matches', 'p2_avg_rt_ms')
    op.drop_column('matches', 'p1_avg_rt_ms')

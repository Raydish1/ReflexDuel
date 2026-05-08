"""add calibration_rounds table

Revision ID: b3e7f92a1c04
Revises: dd73f40c95ec
Create Date: 2026-05-07

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b3e7f92a1c04'
down_revision: Union[str, Sequence[str], None] = 'dd73f40c95ec'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table('calibration_rounds',
    sa.Column('id', sa.Integer(), autoincrement=True, nullable=False),
    sa.Column('player_id', sa.String(length=16), nullable=False),
    sa.Column('rt_ms', sa.Float(), nullable=False),
    sa.Column('side', sa.String(length=5), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['player_id'], ['players.id'], ),
    sa.PrimaryKeyConstraint('id')
    )


def downgrade() -> None:
    op.drop_table('calibration_rounds')

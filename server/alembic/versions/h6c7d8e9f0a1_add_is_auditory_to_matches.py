"""add is_auditory to matches

Revision ID: h6c7d8e9f0a1
Revises: g5b6c7d8e9f0
Create Date: 2026-05-21
"""
from alembic import op
import sqlalchemy as sa

revision = 'h6c7d8e9f0a1'
down_revision = 'g5b6c7d8e9f0'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('matches', sa.Column('is_auditory', sa.Boolean(), nullable=False, server_default='false'))


def downgrade() -> None:
    op.drop_column('matches', 'is_auditory')

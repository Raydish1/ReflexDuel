"""add is_auditory to ffa_matches

Revision ID: j8e9f0a1b2c3
Revises: i7d8e9f0a1b2
Create Date: 2026-05-21
"""
from alembic import op
import sqlalchemy as sa

revision = 'j8e9f0a1b2c3'
down_revision = 'i7d8e9f0a1b2'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('ffa_matches', sa.Column('is_auditory', sa.Boolean(), nullable=False, server_default='false'))


def downgrade() -> None:
    op.drop_column('ffa_matches', 'is_auditory')

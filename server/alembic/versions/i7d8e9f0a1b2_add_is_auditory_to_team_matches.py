"""add is_auditory to team_matches

Revision ID: i7d8e9f0a1b2
Revises: h6c7d8e9f0a1
Create Date: 2026-05-21
"""
from alembic import op
import sqlalchemy as sa

revision = 'i7d8e9f0a1b2'
down_revision = 'h6c7d8e9f0a1'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('team_matches', sa.Column('is_auditory', sa.Boolean(), nullable=False, server_default='false'))


def downgrade() -> None:
    op.drop_column('team_matches', 'is_auditory')

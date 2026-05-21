"""add_team_match_tables

Revision ID: c1d2e3f4a5b6
Revises: a1b2c3d4e5f6
Create Date: 2026-05-12 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c1d2e3f4a5b6'
down_revision: Union[str, Sequence[str], None] = 'a1b2c3d4e5f6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'team_matches',
        sa.Column('id', sa.String(16), primary_key=True),
        sa.Column('t1_p1_id', sa.String(16), sa.ForeignKey('players.id'), nullable=False),
        sa.Column('t1_p2_id', sa.String(16), sa.ForeignKey('players.id'), nullable=False),
        sa.Column('t2_p1_id', sa.String(16), sa.ForeignKey('players.id'), nullable=False),
        sa.Column('t2_p2_id', sa.String(16), sa.ForeignKey('players.id'), nullable=False),
        sa.Column('t1_p1_username', sa.String(32), nullable=False),
        sa.Column('t1_p2_username', sa.String(32), nullable=False),
        sa.Column('t2_p1_username', sa.String(32), nullable=False),
        sa.Column('t2_p2_username', sa.String(32), nullable=False),
        sa.Column('winner_team', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('t1_score', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('t2_score', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('started_at', sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_table(
        'team_rounds',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('match_id', sa.String(16), sa.ForeignKey('team_matches.id', ondelete='CASCADE'), nullable=False),
        sa.Column('round_num', sa.Integer(), nullable=False),
        sa.Column('t_stimulus_us', sa.BigInteger(), nullable=False),
        sa.Column('delay_s', sa.Float(), nullable=False),
        sa.Column('t1_p1_rt_ms', sa.Float(), nullable=True),
        sa.Column('t1_p2_rt_ms', sa.Float(), nullable=True),
        sa.Column('t2_p1_rt_ms', sa.Float(), nullable=True),
        sa.Column('t2_p2_rt_ms', sa.Float(), nullable=True),
        sa.Column('t1_p1_pre_click', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('t1_p2_pre_click', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('t2_p1_pre_click', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('t2_p2_pre_click', sa.Boolean(), nullable=False, server_default='false'),
        sa.Column('t1_combined_ms', sa.Float(), nullable=True),
        sa.Column('t2_combined_ms', sa.Float(), nullable=True),
        sa.Column('winner_team', sa.Integer(), nullable=False, server_default='0'),
    )


def downgrade() -> None:
    op.drop_table('team_rounds')
    op.drop_table('team_matches')

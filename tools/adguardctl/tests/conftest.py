"""Shared pytest fixtures for adguardctl tests."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from adguardctl.api import AdGuard
from adguardctl.client import AdGuardClient

BASE = "http://adguard.local:3000/control"

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def base_url() -> str:
    """Return the control-API base URL used in tests."""
    return BASE


@pytest.fixture
def load_fixture() -> Any:
    """Return a loader for JSON fixtures under ``tests/fixtures``."""

    def _load(name: str) -> Any:
        return json.loads((FIXTURES / name).read_text())

    return _load


@pytest.fixture
def adguard() -> AdGuard:
    """Return an :class:`AdGuard` facade pointed at the test base URL."""
    return AdGuard(AdGuardClient("adguard.local"))

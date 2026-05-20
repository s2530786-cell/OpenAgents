"""Tests for the component-level health check endpoint."""
import os
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient
from api.main import app

client = TestClient(app)


def test_health_returns_200_when_all_healthy():
    """With all components healthy, returns 200 and status=healthy."""
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "healthy"
    assert "components" in data
    assert "database" in data["components"]
    assert "disk" in data["components"]
    assert "memory" in data["components"]


def test_health_includes_latency_ms():
    """Response includes per-component and total latency."""
    resp = client.get("/health")
    data = resp.json()
    assert isinstance(data["latency_ms"], (int, float))
    for comp_key in ("database", "disk", "memory"):
        comp = data["components"][comp_key]
        assert "latency_ms" in comp


def test_health_cache_control_header():
    """Response includes Cache-Control with max-age=10."""
    resp = client.get("/health")
    assert "cache-control" in resp.headers
    assert "max-age=10" in resp.headers["cache-control"]


def test_health_has_agents_tasks_count():
    """Legacy fields agents_indexed and tasks_indexed are preserved."""
    resp = client.get("/health")
    data = resp.json()
    assert isinstance(data["agents_indexed"], int)
    assert isinstance(data["tasks_indexed"], int)


def test_health_timestamp_is_iso():
    """Timestamp is ISO format."""
    resp = client.get("/health")
    data = resp.json()
    assert "T" in data["timestamp"]


def test_health_response_under_5s():
    """Response should complete in under 5 seconds."""
    import time
    t0 = time.perf_counter()
    resp = client.get("/health")
    elapsed = time.perf_counter() - t0
    assert resp.status_code in (200, 503)
    assert elapsed < 5.0


def test_health_db_failure_reflects_unhealthy():
    """When DB check fails, component shows unhealthy."""
    with patch("api.main._check_db") as mock_db:
        mock_db.return_value = {"status": "unhealthy", "latency_ms": 1.5, "error": "simulated"}
        resp = client.get("/health")
        data = resp.json()
        assert data["status"] == "unhealthy"
        assert data["components"]["database"]["status"] == "unhealthy"


def test_health_503_when_any_unhealthy():
    """Returns 503 HTTP status when a component is unhealthy."""
    with patch("api.main._check_db") as mock_db:
        mock_db.return_value = {"status": "unhealthy", "latency_ms": 1.5, "error": "simulated"}
        resp = client.get("/health")
        assert resp.status_code == 503

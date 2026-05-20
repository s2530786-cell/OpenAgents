"""Tests for CORS middleware configuration on the OpenAgents API."""
import os
from fastapi.testclient import TestClient
from api.main import app

client = TestClient(app)


def test_cors_headers_present_in_normal_response():
    """Normal GET responses include CORS headers."""
    resp = client.get("/health")
    assert resp.status_code == 200
    assert "access-control-allow-origin" in resp.headers
    assert "access-control-allow-credentials" in resp.headers


def test_cors_preflight_options():
    """OPTIONS preflight returns proper CORS headers."""
    resp = client.options("/agents", headers={
        "Origin": "http://localhost:3000",
        "Access-Control-Request-Method": "GET",
    })
    assert resp.status_code == 200
    assert "access-control-allow-origin" in resp.headers
    assert "access-control-allow-methods" in resp.headers
    # allowed methods should include GET, POST, PUT, DELETE, OPTIONS
    methods = resp.headers["access-control-allow-methods"]
    for verb in ("GET", "POST", "PUT", "DELETE", "OPTIONS"):
        assert verb in methods


def test_cors_credentials_allowed():
    """Credentials header is set to true."""
    resp = client.get("/health")
    assert resp.headers.get("access-control-allow-credentials") == "true"


def test_cors_allows_configured_origin():
    """Response reflects the requesting origin when it's in the allowed list."""
    origin = "http://localhost:3000"
    resp = client.get("/health", headers={"Origin": origin})
    assert resp.status_code == 200
    # The mirrored origin or the allowed origin list
    acao = resp.headers["access-control-allow-origin"]
    assert acao in (origin, "*") or origin in acao


def test_cors_cross_origin_get():
    """Cross-origin GET request succeeds with CORS headers."""
    resp = client.get("/agents", headers={"Origin": "http://localhost:5173"})
    assert resp.status_code == 200
    assert "access-control-allow-origin" in resp.headers


def test_cors_header_present_on_404():
    """Even 404 responses include CORS headers."""
    resp = client.get("/nonexistent", headers={"Origin": "http://localhost:3000"})
    assert resp.status_code == 404
    assert "access-control-allow-origin" in resp.headers

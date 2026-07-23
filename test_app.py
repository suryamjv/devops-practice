from app import app


def test_health_endpoint_exists():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code in (200, 503)


def test_index_route_registered():
    routes = [r.rule for r in app.url_map.iter_rules()]
    assert "/" in routes
    assert "/health" in routes
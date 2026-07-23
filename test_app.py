import app as app_module


def test_health_returns_200():
    client = app_module.app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "healthy"


def test_index_increments_counter():
    client = app_module.app.test_client()
    first = client.get("/").get_json()["visits"]
    second = client.get("/").get_json()["visits"]
    assert second == first + 1


def test_index_returns_json():
    resp = app_module.app.test_client().get("/")
    assert resp.status_code == 200
    assert "message" in resp.get_json()
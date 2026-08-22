from app import add, app


def test_add():
    assert add(2, 3) == 5


def test_health():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_index():
    client = app.test_client()
    assert client.get("/").status_code == 200

"""
Basic proxy functionality tests.

Tests that the load balancer correctly forwards:
- Different HTTP methods (GET, POST, PUT, PATCH)
- Request bodies
- Request URIs
"""
import requests
import pytest


@pytest.mark.timeout(20)
def test_get_request_forwarded(load_balancer):
    """Test that GET requests are forwarded to the backend."""
    response = requests.get(f"{load_balancer}/", timeout=5)

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "GET"
    assert data["uri"] == "/"
    assert "server_id" in data


@pytest.mark.timeout(20)
def test_post_request_with_body(load_balancer):
    """Test that POST requests with JSON body are forwarded correctly."""
    request_body = {"test": "data", "number": 42}

    response = requests.post(
        f"{load_balancer}/",
        json=request_body,
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "POST"
    assert data["uri"] == "/"
    # The body should be the JSON string representation
    assert "test" in data["body"]
    assert "data" in data["body"]
    assert data["body_length"] > 0


@pytest.mark.timeout(20)
def test_put_request_with_body(load_balancer):
    """Test that PUT requests with body are forwarded correctly."""
    request_body = {"action": "update", "value": 123}

    response = requests.put(
        f"{load_balancer}/api/resource",
        json=request_body,
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "PUT"
    assert data["uri"] == "/api/resource"
    assert "action" in data["body"]
    assert "update" in data["body"]
    assert data["body_length"] > 0


@pytest.mark.timeout(20)
def test_patch_request_with_body(load_balancer):
    """Test that PATCH requests with body are forwarded correctly."""
    request_body = {"field": "name", "value": "new_value"}

    response = requests.patch(
        f"{load_balancer}/api/resource/123",
        json=request_body,
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "PATCH"
    assert data["uri"] == "/api/resource/123"
    assert "field" in data["body"]
    assert "name" in data["body"]
    assert data["body_length"] > 0


@pytest.mark.timeout(20)
def test_response_contains_request_info(load_balancer):
    """Test that echo server returns complete request information."""
    response = requests.get(f"{load_balancer}/test/path", timeout=5)

    assert response.status_code == 200
    data = response.json()

    # Verify all expected fields are present
    assert "server_id" in data
    assert "method" in data
    assert "uri" in data
    assert "headers" in data
    assert "body" in data
    assert "body_length" in data

    # Verify values
    assert data["method"] == "GET"
    assert data["uri"] == "/test/path"
    assert isinstance(data["headers"], dict)
    assert data["body_length"] == 0  # GET request has no body

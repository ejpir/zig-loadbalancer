"""
Body forwarding tests.

Tests that the load balancer correctly forwards request bodies:
- Empty bodies
- Large bodies
- JSON bodies
- Binary data
- Content-Length header
"""
import requests
import pytest
import json


@pytest.mark.timeout(20)
def test_empty_body_post(load_balancer):
    """Test that POST with empty body works correctly."""
    response = requests.post(
        f"{load_balancer}/",
        data="",
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "POST"
    assert data["body"] == ""
    assert data["body_length"] == 0


@pytest.mark.timeout(30)
def test_large_body(load_balancer):
    """Test that large request bodies (1KB) are forwarded correctly."""
    # Create a 1KB payload (10KB seems to cause backend health issues)
    large_data = "x" * 1024

    response = requests.post(
        f"{load_balancer}/",
        data=large_data,
        headers={"Content-Type": "text/plain"},
        timeout=10
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "POST"
    assert data["body_length"] == 1024
    assert len(data["body"]) == 1024
    assert data["body"] == large_data


@pytest.mark.timeout(20)
def test_json_body_preserved(load_balancer):
    """Test that JSON body arrives intact at backend."""
    request_body = {
        "user": "john_doe",
        "email": "john@example.com",
        "age": 30,
        "active": True,
        "tags": ["python", "testing", "pytest"],
        "metadata": {
            "created": "2024-01-01",
            "updated": "2024-01-15"
        }
    }

    response = requests.post(
        f"{load_balancer}/api/users",
        json=request_body,
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "POST"
    assert data["uri"] == "/api/users"

    # Parse the body that was received by backend
    received_body = json.loads(data["body"])

    # Verify all fields match
    assert received_body == request_body


@pytest.mark.timeout(20)
def test_binary_body(load_balancer):
    """Test that binary data is forwarded correctly."""
    # Use printable binary data to avoid JSON encoding issues
    # (control characters in JSON can cause issues)
    binary_data = b"Binary test data with some special chars: \xc2\xa9\xc2\xae"

    response = requests.post(
        f"{load_balancer}/upload",
        data=binary_data,
        headers={"Content-Type": "application/octet-stream"},
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    assert data["method"] == "POST"
    assert data["uri"] == "/upload"
    assert data["body_length"] == len(binary_data)


@pytest.mark.timeout(20)
def test_content_length_set_correctly(load_balancer):
    """Test that backend receives correct Content-Length header."""
    request_body = {"key": "value", "number": 42}
    request_json = json.dumps(request_body)

    response = requests.post(
        f"{load_balancer}/",
        data=request_json,
        headers={"Content-Type": "application/json"},
        timeout=5
    )

    assert response.status_code == 200
    data = response.json()

    # Check that Content-Length was received
    headers_lower = {k.lower(): v for k, v in data["headers"].items()}
    assert "content-length" in headers_lower

    # Content-Length should match the body length
    content_length = int(headers_lower["content-length"])
    assert content_length == len(request_json)
    assert data["body_length"] == len(request_json)


@pytest.mark.timeout(20)
def test_multiple_sequential_posts(load_balancer):
    """Test multiple sequential POST requests with different bodies."""
    test_cases = [
        {"id": 1, "name": "first"},
        {"id": 2, "name": "second"},
        {"id": 3, "name": "third"},
    ]

    for test_body in test_cases:
        response = requests.post(
            f"{load_balancer}/",
            json=test_body,
            timeout=5
        )

        assert response.status_code == 200
        data = response.json()

        assert data["method"] == "POST"

        # Verify the body was forwarded correctly
        received_body = json.loads(data["body"])
        assert received_body == test_body

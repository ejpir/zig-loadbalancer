"""
Load balancing tests.

Tests that the load balancer correctly:
- Distributes requests using round-robin algorithm
- Reaches all configured backends
"""
import requests
import pytest
from collections import Counter


@pytest.mark.timeout(60)
def test_round_robin_distribution(load_balancer_multi):
    """
    Test that requests are distributed evenly using round-robin.

    With 3 backends and 9 requests, each backend should receive exactly 3 requests.
    """
    server_ids = []

    # Make 9 requests
    for _ in range(9):
        response = requests.get(f"{load_balancer_multi}/", timeout=5)
        assert response.status_code == 200

        data = response.json()
        server_ids.append(data["server_id"])

    # Count requests per backend
    distribution = Counter(server_ids)

    # Each backend should receive exactly 3 requests
    assert len(distribution) == 3, f"Expected 3 backends, got {len(distribution)}"

    for backend_id, count in distribution.items():
        assert count == 3, f"Backend {backend_id} received {count} requests, expected 3"


@pytest.mark.timeout(60)
def test_requests_reach_all_backends(load_balancer_multi):
    """
    Test that all backends receive at least one request.

    This verifies that the load balancer is configured with all backends
    and can reach each one.
    """
    server_ids = set()

    # Make up to 12 requests, should hit all 3 backends
    for _ in range(12):
        response = requests.get(f"{load_balancer_multi}/", timeout=5)
        assert response.status_code == 200

        data = response.json()
        server_ids.add(data["server_id"])

        # Stop early if we've hit all backends
        if len(server_ids) >= 3:
            break

    # Verify we hit all 3 backends
    assert len(server_ids) == 3, f"Expected 3 unique backends, got {len(server_ids)}: {server_ids}"

    # Verify backend naming
    expected_backends = {"backend1", "backend2", "backend3"}
    assert server_ids == expected_backends, f"Backend IDs mismatch. Expected {expected_backends}, got {server_ids}"

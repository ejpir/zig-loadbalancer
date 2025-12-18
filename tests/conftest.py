"""
Pytest fixtures for load balancer integration tests.

Provides fixtures for starting/stopping:
- Backend echo servers
- Load balancer instances
"""
import os
import signal
import socket
import subprocess
import time
from typing import List, Tuple
import pytest
import atexit


# Track all processes for cleanup
_all_processes = []


def cleanup_all_processes():
    """Kill all tracked processes on exit."""
    for process in _all_processes:
        try:
            if process.poll() is None:  # Process is still running
                # Kill process group
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                except Exception:
                    pass
                process.kill()
                process.wait(timeout=2)
        except Exception:
            pass


atexit.register(cleanup_all_processes)


def wait_for_port(port: int, timeout: int = 10) -> bool:
    """
    Wait for a port to be ready to accept connections.

    Args:
        port: Port number to check
        timeout: Maximum seconds to wait

    Returns:
        True if port becomes available, False if timeout
    """
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex(('127.0.0.1', port))
            sock.close()
            if result == 0:
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def start_backend(port: int, server_id: str) -> subprocess.Popen:
    """
    Start an echo backend server on the given port.

    Args:
        port: Port number for the backend
        server_id: Identifier for this backend instance

    Returns:
        Popen process object
    """
    # Get the project root directory (parent of tests/)
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    backend_binary = os.path.join(project_root, "zig-out", "bin", "test_backend_echo")

    if not os.path.exists(backend_binary):
        raise FileNotFoundError(
            f"Backend binary not found at {backend_binary}. Run 'zig build' first."
        )

    process = subprocess.Popen(
        [backend_binary, "--port", str(port), "--id", server_id],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
    )

    # Track for cleanup
    _all_processes.append(process)

    # Wait for the port to be ready
    if not wait_for_port(port, timeout=10):
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:
            pass
        process.kill()
        process.wait()
        raise RuntimeError(f"Backend {server_id} failed to start on port {port}")

    return process


def start_load_balancer(backend_ports: List[int], lb_port: int = 18080) -> subprocess.Popen:
    """
    Start the load balancer pointing to the given backends.

    Args:
        backend_ports: List of backend port numbers
        lb_port: Port for the load balancer

    Returns:
        Popen process object
    """
    # Get the project root directory (parent of tests/)
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lb_binary = os.path.join(project_root, "zig-out", "bin", "load_balancer_mp")

    if not os.path.exists(lb_binary):
        raise FileNotFoundError(
            f"Load balancer binary not found at {lb_binary}. Run 'zig build' first."
        )

    # Build command line arguments
    # Limit to 2 workers for tests to avoid high CPU usage
    cmd = [lb_binary, "--port", str(lb_port), "-w", "2"]
    for port in backend_ports:
        cmd.extend(["--backend", f"127.0.0.1:{port}"])

    process = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
    )

    # Track for cleanup
    _all_processes.append(process)

    # Wait for the port to be ready
    if not wait_for_port(lb_port, timeout=10):
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:
            pass
        process.kill()
        process.wait()
        raise RuntimeError(f"Load balancer failed to start on port {lb_port}")

    # Backends start as healthy by default, but health probe needs time to verify
    # 1s initial delay + first probe cycle
    time.sleep(5)

    return process


@pytest.fixture(scope="module")
def backend() -> str:
    """
    Start a single echo backend server.

    Yields:
        URL of the backend server (e.g., "http://127.0.0.1:19001")
    """
    port = 19001
    server_id = "backend1"

    process = start_backend(port, server_id)

    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:
            pass
        process.kill()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


@pytest.fixture(scope="module")
def backends() -> Tuple[str, str, str]:
    """
    Start three echo backend servers for load balancing tests.

    Yields:
        Tuple of three backend URLs
    """
    ports = [19001, 19002, 19003]
    server_ids = ["backend1", "backend2", "backend3"]
    processes = []

    try:
        for port, server_id in zip(ports, server_ids):
            process = start_backend(port, server_id)
            processes.append(process)

        yield tuple(f"http://127.0.0.1:{port}" for port in ports)
    finally:
        for process in processes:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            except Exception:
                pass
            process.kill()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


@pytest.fixture(scope="module")
def load_balancer(backend) -> str:
    """
    Start load balancer with a single backend.

    Yields:
        URL of the load balancer (e.g., "http://127.0.0.1:18080")
    """
    lb_port = 18080
    backend_port = 19001

    process = start_load_balancer([backend_port], lb_port)

    try:
        yield f"http://127.0.0.1:{lb_port}"
    finally:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:
            pass
        process.kill()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


@pytest.fixture(scope="module")
def load_balancer_multi(backends) -> str:
    """
    Start load balancer with three backends.

    Yields:
        URL of the load balancer (e.g., "http://127.0.0.1:18080")
    """
    lb_port = 18080
    backend_ports = [19001, 19002, 19003]

    process = start_load_balancer(backend_ports, lb_port)

    try:
        yield f"http://127.0.0.1:{lb_port}"
    finally:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except Exception:
            pass
        process.kill()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()

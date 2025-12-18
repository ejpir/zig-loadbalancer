import subprocess
import time

def test_direct():
    backend = subprocess.Popen(
        ['../zig-out/bin/test_backend_echo', '--port', '19001', '--id', 'test'],
    )
    time.sleep(1)

    lb = subprocess.Popen(
        ['../zig-out/bin/load_balancer_mp', '--port', '18080', '-w', '1', '--backend', '127.0.0.1:19001'],
    )

    print("\n>>> Check CPU now! <<<")
    time.sleep(5)

    lb.terminate()
    backend.terminate()

if __name__ == "__main__":
    test_direct()

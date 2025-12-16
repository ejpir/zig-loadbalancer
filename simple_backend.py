#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import sys

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = f"<html><body><h1>Hello from Python Backend {sys.argv[1]}!</h1></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", len(body))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass  # Suppress logging

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9001
    server = ThreadedHTTPServer(("127.0.0.1", port), Handler)
    print(f"Python backend {sys.argv[1]} listening on port {port}")
    server.serve_forever()

from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'Backend 9001\n')

    def log_message(self, format, *args):
        print(f"[9001] {args[0]}")

if __name__ == "__main__":
    print("Starting backend on port 9001...")
    HTTPServer(('127.0.0.1', 9001), Handler).serve_forever()

from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'Backend 9002\n')

    def log_message(self, format, *args):
        print(f"[9002] {args[0]}")

if __name__ == "__main__":
    print("Starting backend on port 9002...")
    HTTPServer(('127.0.0.1', 9002), Handler).serve_forever()

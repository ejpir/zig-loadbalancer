"""
HTTP/2 Test Backend for Integration Tests

An ASGI application that echoes request details in JSON format.
Run with hypercorn for HTTP/2 support:

    hypercorn h2_backend:app --bind 0.0.0.0:9443 \
        --certfile ../test_certs/cert.pem \
        --keyfile ../test_certs/key.pem
"""

import json


async def app(scope, receive, send):
    """ASGI application that echoes request details."""
    if scope["type"] != "http":
        return

    # Read request body
    body = b""
    while True:
        message = await receive()
        body += message.get("body", b"")
        if not message.get("more_body", False):
            break

    # Build response
    headers = {k.decode(): v.decode() for k, v in scope.get("headers", [])}

    response_data = {
        "server_id": "h2_backend",
        "method": scope["method"],
        "uri": scope["path"] + ("?" + scope["query_string"].decode() if scope.get("query_string") else ""),
        "headers": headers,
        "body": body.decode("utf-8", errors="replace"),
        "body_length": len(body),
        "http_version": scope.get("http_version", "2"),
    }

    response_body = json.dumps(response_data).encode()

    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [
            [b"content-type", b"application/json"],
            [b"content-length", str(len(response_body)).encode()],
        ],
    })

    await send({
        "type": "http.response.body",
        "body": response_body,
    })

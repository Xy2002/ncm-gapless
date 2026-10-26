"""Evaluate an explicitly supplied script in a local NetEase CEF page.

This development tool never reads cookies, storage, or network responses.
Use only against a client you own. websocket-client is a development dependency.
"""

import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener

PAGE_URLS = ("orpheus://orpheus/pub/app.html", "orpheus://orpheus/app.html")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


def get_page(port: int):
    if not 1 <= port <= 65535:
        raise RuntimeError("NCM_PORT_INVALID")
    opener = build_opener(ProxyHandler({}), NoRedirect())
    with opener.open(f"http://127.0.0.1:{port}/json/list", timeout=2) as response:
        pages = json.loads(response.read(1024 * 1024))
    if not isinstance(pages, list) or any(not isinstance(page, dict) for page in pages):
        raise RuntimeError("NCM_PAGE_LIST_INVALID")
    matches = [p for p in pages if p.get("type") == "page" and p.get("url") in PAGE_URLS]
    if len(matches) != 1:
        raise RuntimeError("NCM_PAGE_NOT_UNIQUE")
    endpoint = matches[0].get("webSocketDebuggerUrl", "")
    if not isinstance(endpoint, str):
        raise RuntimeError("NCM_ENDPOINT_NOT_LOOPBACK")
    socket = urlsplit(endpoint)
    if (socket.scheme != "ws" or socket.hostname != "127.0.0.1" or socket.port != port
            or socket.username or socket.password or socket.fragment
            or not socket.path.startswith("/devtools/page/")):
        raise RuntimeError("NCM_ENDPOINT_NOT_LOOPBACK")
    return endpoint


def evaluate(port: int, expression: str, *, user_gesture: bool = False):
    import websocket

    endpoint = get_page(port)
    try:
        connection = websocket.create_connection(
            endpoint, timeout=20, suppress_origin=True, http_no_proxy=["127.0.0.1"],
            redirect_limit=0,
        )
    except websocket.WebSocketException:
        raise RuntimeError("NCM_CDP_CONNECTION_FAILED") from None
    try:
        connection.send(json.dumps({
            "id": 1, "method": "Runtime.evaluate", "params": {
                "expression": expression, "returnByValue": True,
                "awaitPromise": True, "timeout": 15000,
                "userGesture": user_gesture,
            },
        }))
        while True:
            result = json.loads(connection.recv())
            if result.get("id") == 1:
                return result
    except websocket.WebSocketException:
        raise RuntimeError("NCM_CDP_CONNECTION_FAILED") from None
    finally:
        connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--script", type=Path, required=True)
    arguments = parser.parse_args()
    response = evaluate(arguments.port, arguments.script.read_text(encoding="utf-8"))
    if "exceptionDetails" in response.get("result", {}):
        # RPC error objects can contain request headers or bodies. Never dump them.
        details = response["result"]["exceptionDetails"]
        print(json.dumps({"error": "SCRIPT_EXCEPTION", "class": details.get("exception", {}).get("className", "unknown")}, indent=2))
        raise SystemExit(1)
    print(json.dumps(response, ensure_ascii=False, indent=2))

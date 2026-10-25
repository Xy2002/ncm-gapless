"""Evaluate an explicitly supplied script in a local NetEase CEF page.

This development tool never reads cookies, storage, or network responses.
Use only against a client you own. websocket-client is a development dependency.
"""

import argparse
import json
from pathlib import Path
from urllib.request import urlopen

import websocket


def evaluate(port: int, expression: str, *, user_gesture: bool = False):
    with urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as response:
        pages = json.load(response)
    matches = [p for p in pages if p.get("url") == "orpheus://orpheus/pub/app.html"]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one NetEase main page")
    connection = websocket.create_connection(
        matches[0]["webSocketDebuggerUrl"], timeout=20, suppress_origin=True
    )
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

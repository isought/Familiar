"""Private stdio MCP bridge between Claude Code and a running Noteling request.

Only the tools in tools.json are exposed. No network listener, imports of tool
packs, credentials, or direct execution: Noteling retains its normal executor.
"""
import json
import os
from pathlib import Path
import sys
import time
import uuid


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False)
    os.replace(temporary, path)


def tool_result(message):
    return {"content": [{"type": "text", "text": message}], "isError": True}


def call_tool(root, names, params):
    name = params.get("name")
    arguments = params.get("arguments", {})
    if not isinstance(name, str) or name not in names or not isinstance(arguments, dict):
        return tool_result("Unknown tool or invalid arguments.")
    identifier = uuid.uuid4().hex
    request = root / "requests" / (identifier + ".json")
    response = root / "responses" / (identifier + ".json")
    parent = os.getppid()
    try:
        write_json(request, {"name": name, "arguments": arguments})
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if response.exists():
                with response.open(encoding="utf-8") as handle:
                    result = json.load(handle)
                response.unlink(missing_ok=True)
                return result
            if not root.exists() or os.getppid() != parent:
                return tool_result("Noteling request has ended.")
            time.sleep(0.04)
        return tool_result("Noteling tool timed out.")
    finally:
        request.unlink(missing_ok=True)


def main():
    os.umask(0o077)
    root = Path(sys.argv[1])
    with (root / "tools.json").open(encoding="utf-8") as handle:
        definitions = json.load(handle)
    names = {tool["name"] for tool in definitions}
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(message, dict) or "id" not in message:
            continue  # Initialized/cancelled notifications need no response.
        identifier, method = message["id"], message.get("method")
        response = {"jsonrpc": "2.0", "id": identifier}
        params = message.get("params") or {}
        if not isinstance(params, dict):
            response["error"] = {"code": -32602, "message": "Invalid parameters"}
        elif method == "initialize":
            response["result"] = {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "noteling", "version": "1.0.0"},
            }
        elif method == "ping":
            response["result"] = {}
        elif method == "tools/list":
            response["result"] = {"tools": definitions}
        elif method == "tools/call":
            try:
                response["result"] = call_tool(root, names, params)
            except (OSError, ValueError):
                response["result"] = tool_result("Noteling tool bridge is unavailable.")
        else:
            response["error"] = {"code": -32601, "message": "Method not found"}
        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()

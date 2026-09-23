"""Familiar helper: execute a script's run(**args) and print JSON.

Usage: python run_tool.py path/to/script.py   (JSON args on stdin)
Anything the script prints goes into "stdout" so it can't corrupt the result.
"""
import contextlib
import importlib.util
import io
import json
import sys
import traceback


def main():
    path = sys.argv[1]
    raw = sys.stdin.read()
    args = json.loads(raw) if raw.strip() else {}
    buf = io.StringIO()
    try:
        spec = importlib.util.spec_from_file_location("familiar_tool", path)
        mod = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stdout(buf):
            spec.loader.exec_module(mod)
            result = mod.run(**args)
        out = {"result": result}
        if buf.getvalue().strip():
            out["stdout"] = buf.getvalue()[-4000:]
        print(json.dumps(out, default=str))
        return 0
    except Exception as e:  # noqa: BLE001
        out = {"error": f"{type(e).__name__}: {e}", "traceback": traceback.format_exc()[-3000:]}
        if buf.getvalue().strip():
            out["stdout"] = buf.getvalue()[-4000:]
        print(json.dumps(out, default=str))
        return 1


if __name__ == "__main__":
    sys.exit(main())

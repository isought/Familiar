"""Familiar helper: turn a script's run() function into a JSON tool schema.

Uses `ast` only, so it never imports the script or needs its dependencies.
Usage: python introspect.py path/to/script.py  -> JSON on stdout
"""
import ast
import json
import re
import sys

SIMPLE = {"str": "string", "int": "integer", "float": "number", "bool": "boolean",
          "list": "array", "dict": "object", "Any": "string"}


def type_of(node):
    """Return (json_type_dict, optional) for an annotation node."""
    if node is None:
        return {"type": "string"}, False
    if isinstance(node, ast.Constant) and node.value is None:
        return {"type": "null"}, True
    if isinstance(node, ast.Name):
        return {"type": SIMPLE.get(node.id, "string")}, False
    if isinstance(node, ast.Attribute):
        return {"type": SIMPLE.get(node.attr, "string")}, False
    if isinstance(node, ast.Subscript):
        base = node.value.id if isinstance(node.value, ast.Name) else getattr(node.value, "attr", "")
        inner = node.slice
        if base in ("Optional",):
            t, _ = type_of(inner)
            return t, True
        if base in ("list", "List"):
            t, _ = type_of(inner)
            return {"type": "array", "items": t}, False
        if base in ("dict", "Dict"):
            return {"type": "object"}, False
        if base in ("Literal",):
            vals = inner.elts if isinstance(inner, ast.Tuple) else [inner]
            enum = [v.value for v in vals if isinstance(v, ast.Constant)]
            return {"type": "string", "enum": enum}, False
        return {"type": "string"}, False
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):  # X | None
        left, lo = type_of(node.left)
        right, ro = type_of(node.right)
        if right.get("type") == "null":
            return left, True
        if left.get("type") == "null":
            return right, True
        return left, lo or ro
    return {"type": "string"}, False


def param_docs(doc):
    out = {}
    m = re.search(r"^\s*(?:Args|Arguments|Parameters)\s*:\s*\n((?:[ \t]+\S.*\n?)+)", doc, re.M)
    if not m:
        return out
    current = None
    for line in m.group(1).splitlines():
        mm = re.match(r"^\s*(\w+)\s*(?:\([^)]*\))?\s*:\s*(.*)$", line)
        if mm:
            current = mm.group(1)
            out[current] = mm.group(2).strip()
        elif current and line.strip():
            out[current] += " " + line.strip()
    return out


def dependencies(src):
    m = re.search(r"^# /// script\s*$(.*?)^# ///\s*$", src, re.S | re.M)
    if not m:
        return []
    toml = "\n".join(l[2:] if l.startswith("# ") else l[1:] for l in m.group(1).splitlines())
    try:
        import tomllib  # 3.11+
        return list(tomllib.loads(toml).get("dependencies", []))
    except Exception:
        mm = re.search(r"dependencies\s*=\s*\[(.*?)\]", toml, re.S)
        return re.findall(r"[\"']([^\"']+)[\"']", mm.group(1)) if mm else []


def main(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    tree = ast.parse(src)
    run = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run"), None)
    if run is None:
        print(json.dumps({"error": "no top-level run() function"}))
        return 1
    doc = ast.get_docstring(run) or ast.get_docstring(tree) or ""
    description = doc.strip().split("\n\n")[0].strip().replace("\n", " ") or f"Run {path}"
    pdocs = param_docs(doc)

    a = run.args
    defaults = {}
    for arg, d in zip(a.args[len(a.args) - len(a.defaults):], a.defaults):
        defaults[arg.arg] = d
    for arg, d in zip(a.kwonlyargs, a.kw_defaults):
        if d is not None:
            defaults[arg.arg] = d

    props, required = {}, []
    for arg in a.args + a.kwonlyargs:
        if arg.arg == "self":
            continue
        t, optional = type_of(arg.annotation)
        p = dict(t)
        if arg.arg in pdocs:
            p["description"] = pdocs[arg.arg]
        if arg.arg in defaults:
            try:
                p["default"] = ast.literal_eval(defaults[arg.arg])
            except Exception:
                pass
        elif not optional:
            required.append(arg.arg)
        props[arg.arg] = p

    print(json.dumps({
        "description": description,
        "input_schema": {"type": "object", "properties": props, "required": required},
        "dependencies": dependencies(src),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

"""Copy text to the user's clipboard so they can paste it.

Args:
    text: The text to copy.
"""
import subprocess


def run(text: str) -> dict:
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=False)
    return {"copied_chars": len(text)}

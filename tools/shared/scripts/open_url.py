"""Open a URL in the user's default browser.

Args:
    url: Full URL including https://
"""
import subprocess


def run(url: str) -> dict:
    subprocess.run(["open", url], check=False)
    return {"opened": url}

"""Check whether a VPN tunnel is currently up on this Mac.

Heuristic: a utun interface with an IPv4 address usually means a corporate VPN is connected.
"""
import re
import subprocess


def run() -> dict:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    tunnels = []
    for block in re.split(r"\n(?=\S)", out):
        name = block.split(":")[0]
        if name.startswith(("utun", "ppp", "ipsec", "gpd")) and re.search(r"\n\s+inet \d", block):
            tunnels.append(name)
    return {"vpn_connected": bool(tunnels), "tunnel_interfaces": tunnels}

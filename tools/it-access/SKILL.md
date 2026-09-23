---
name: IT access and VPN
description: VPN (GlobalProtect), access requests, locked accounts, IT help contacts.
match:
  urls: [access.internal.example.com, it.internal.example.com]
  bundles: [com.paloaltonetworks.GlobalProtect]
  titles: [GlobalProtect, Access Hub]
---
VPN is GlobalProtect, portal vpn.example.com. It is required for HR, finance and the wiki, not for email or Slack.
Access to internal systems is requested in the Access Hub; manager approves, then the system owner. 1-2 business days.
Urgent lockouts: phone ext. 4444. Otherwise Slack #it-help.

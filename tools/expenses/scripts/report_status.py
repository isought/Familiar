# /// script
# dependencies = []
# ///
"""Look up the status, approver and next step for an expense report.

Demo implementation with canned data. Replace the body with a call to the real Concur API.

Args:
    report_id: The report name or id as shown in Concur, e.g. "2026-09 Client dinner".
"""
import json
import os


def run(report_id: str) -> dict:
    ctx = json.loads(os.environ.get("FAMILIAR_CONTEXT", "{}"))
    return {
        "report_id": report_id,
        "status": "Pending approval",
        "approver": "your manager (Jamie Lee)",
        "submitted_days_ago": 4,
        "next_step": "Approval is overdue (more than 3 business days). Nudge the approver, then finance-help@example.com.",
        "requested_from_app": ctx.get("appName"),
    }

"""List the current user's recent expense reports with their status.

Demo implementation with canned data.

Args:
    limit: Maximum number of reports to return.
"""


def run(limit: int = 5) -> list:
    reports = [
        {"id": "2026-09 Client dinner", "amount": 212.40, "status": "Pending approval"},
        {"id": "2026-08 Conference travel", "amount": 1480.00, "status": "Paid"},
        {"id": "2026-08 Team lunch", "amount": 96.10, "status": "Returned: missing receipt"},
    ]
    return reports[:limit]

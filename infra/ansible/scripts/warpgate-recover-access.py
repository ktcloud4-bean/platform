#!/usr/bin/env python3
"""WG-04 local Warpgate admin recovery helper.

Warpgate v0.26.1 uses dialoguer raw-terminal input for the confirmation prompt.
ansible.builtin.expect appends a newline and causes that prompt to choose ``no``
in this environment.  This helper sends the affirmative key without a newline.
The password arrives only through the transient process environment and is never
written or printed.
"""

import os
import sys

import pexpect


def fail() -> None:
    """Return a non-secret diagnostic only."""
    print("Warpgate local admin recovery did not reach its completion marker.", file=sys.stderr)
    raise SystemExit(1)


password = os.environ.get("WG04_RECOVER_ACCESS_PASSWORD")
if not password or len(password) < 32:
    fail()

child = pexpect.spawn(
    "/usr/local/bin/warpgate",
    ["--config", "/etc/warpgate.yaml", "recover-access", "admin"],
    cwd="/var/lib/warpgate",
    encoding="utf-8",
    echo=False,
    timeout=30,
)

try:
    child.expect("New password for admin")
    child.sendline(password)
    child.expect(r"Continue\?")
    # dialoguer Confirm reads a single raw key; no newline is permitted here.
    child.send("y")
    child.expect("All done")
    child.expect(pexpect.EOF)
    # pexpect populates exitstatus only after close(), even after matching EOF.
    child.close()
except pexpect.ExceptionPexpect:
    fail()

if child.exitstatus != 0:
    fail()

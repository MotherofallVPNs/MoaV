#!/usr/bin/env python3
"""Regression test for the admin IP whitelist matcher (admin/main.py ip_matches).

The previous matcher stripped digits and dots off a CIDR and used startswith(),
which could never be true for a `/`-terminated string -- so EVERY CIDR entry
denied everyone. It failed closed (never a bypass), but an operator who set a
CIDR locked themselves out and most likely removed the whitelist entirely,
disabling the one mitigation there is for the missing rate limiting.

The repo had zero Python tests, so nothing locked the fix. This does.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "admin", "main.py")

# Import ip_matches WITHOUT running the app: pull just the source of the function.
spec = importlib.util.spec_from_file_location("admin_main", MAIN)
src = open(MAIN).read()
ns = {}
import ipaddress  # noqa: F401  (ip_matches references it)
ns["ipaddress"] = ipaddress
# extract the function definition text and exec only that
start = src.index("def ip_matches(")
end = src.index("\n\n\n", start)
exec(compile(src[start:end], MAIN, "exec"), ns)
ip_matches = ns["ip_matches"]

CASES = [
    # (client_ip, whitelist_entry, expected)
    ("10.1.2.3",    "10.0.0.0/8",     True),   # in CIDR  <- the case that was broken
    ("11.1.2.3",    "10.0.0.0/8",     False),  # outside CIDR
    ("192.168.5.9", "192.168.0.0/16", True),
    ("192.169.5.9", "192.168.0.0/16", False),
    ("1.2.3.4",     "1.2.3.4",        True),   # exact IP
    ("1.2.3.5",     "1.2.3.4",        False),
    ("::1",         "::1/128",        True),   # IPv6 CIDR
    ("2001:db8::5", "2001:db8::/32",  True),
    ("2001:dead::5","2001:db8::/32",  False),
    ("10.1.2.3",    "",               False),  # empty entry -> deny
    ("10.1.2.3",    "not-an-ip/8",    False),  # malformed -> deny (fail closed)
    ("10.1.2.3",    "::1/128",        False),  # family mismatch -> deny
    ("10.1.2.3",    "  10.0.0.0/8  ", True),   # surrounding whitespace tolerated
]

fails = 0
for ip, allowed, expected in CASES:
    got = ip_matches(ip, allowed)
    status = "ok  " if got == expected else "FAIL"
    if got != expected:
        fails += 1
    print(f"  {status} ip_matches({ip!r}, {allowed!r}) = {got}  (want {expected})")

print()
if fails:
    print(f"  {fails} FAILED")
    sys.exit(1)
print(f"  all {len(CASES)} cases pass")

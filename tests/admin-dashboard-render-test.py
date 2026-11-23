#!/usr/bin/env python3
"""Regression test: the admin dashboard must render on the PINNED Python deps.

A Starlette major can break `GET /` (500) while `/api/health` stays green.
Needs: pip install -r admin/requirements.txt
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADMIN = os.path.join(HERE, "..", "admin")

os.environ["ADMIN_PASSWORD"] = "render-test-not-a-real-secret"
os.environ.pop("ADMIN_IP_WHITELIST", None)
os.chdir(ADMIN)  # main.py loads templates from the relative "templates" dir
sys.path.insert(0, ADMIN)

try:
    from fastapi.testclient import TestClient
    import main
except ImportError as e:
    print(f"  FAIL  cannot import the admin app ({e}); "
          "run: pip install -r admin/requirements.txt")
    sys.exit(1)

AUTH = ("any", os.environ["ADMIN_PASSWORD"])
passed = failed = 0


def check(label, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok    {label}")
    else:
        failed += 1
        print(f"  FAIL  {label}")


print("admin dashboard render (pinned deps)")
client = TestClient(main.app, raise_server_exceptions=False)

r = client.get("/api/health")
check("/api/health answers 200 without auth", r.status_code == 200)

r = client.get("/")
check("dashboard without credentials is 401", r.status_code == 401)

r = client.get("/", auth=("any", "wrong-password"))
check("dashboard with a wrong password is 401", r.status_code == 401)

r = client.get("/", auth=AUTH)
check(f"dashboard renders (200, got {r.status_code})", r.status_code == 200)
check("dashboard is HTML", "text/html" in r.headers.get("content-type", ""))
check("dashboard body is the rendered template", "<!DOCTYPE html>" in r.text)

r = client.get("/api/stats", auth=AUTH)
check("/api/stats answers 200 JSON", r.status_code == 200 and isinstance(r.json(), dict))

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""
Cree (ou met a jour) la regle de correlation Keep "Juice Shop - multi-signaux"
via l'API /rules, en s'authentifiant avec un JWT admin auto-signe (role=admin)
plutot que via le flux de login UI.

Ne necessite aucune dependance externe (stdlib uniquement : hmac/hashlib/base64
pour le JWT HS256, urllib pour l'appel HTTP) afin de pouvoir tourner dans un
conteneur Python nu sans "pip install".

Variables d'environnement requises (fournies via env_file sur aiops/.env) :
  KEEP_JWT_SECRET   secret de signature des JWT Keep (meme valeur que le backend)
  KEEP_API_URL      URL de base de l'API Keep (defaut http://keep-backend:8080)
"""
import base64
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request

KEEP_API_URL = os.environ.get("KEEP_API_URL", "http://keep-backend:8080")
JWT_SECRET = os.environ["KEEP_JWT_SECRET"]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_admin_jwt() -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"tenant_id": "keep", "email": "ops-automation@keephq", "role": "admin"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    signature = hmac.new(JWT_SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64url(signature)}"


def main():
    token = make_admin_jwt()

    rule_payload = {
        "ruleName": "Juice Shop - correlation multi-signaux",
        "sqlQuery": {
            "sql": "SELECT * FROM alert where service = %s",
            "params": ["juice-shop"],
        },
        "celQuery": 'service == "juice-shop"',
        "timeframeInSeconds": 180,
        "timeUnit": "seconds",
        "groupingCriteria": ["service"],
        "requireApprove": False,
        "resolveOn": "all",
        "createOn": "any",
        "incidentNameTemplate": "Incident Juice Shop ({{ alert.name }})",
        "threshold": 1,
    }

    data = json.dumps(rule_payload).encode("utf-8")
    req = urllib.request.Request(
        f"{KEEP_API_URL}/rules",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"OK: HTTP {resp.status}")
            print(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"ERREUR HTTP {exc.code}: {exc.read().decode()}")
        raise
    except urllib.error.URLError as exc:
        print(f"ERREUR reseau: {exc}")
        raise


if __name__ == "__main__":
    main()

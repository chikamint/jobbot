"""Fail if any namespaced object from `kubectl kustomize` is outside the expected namespace.

Usage: kubectl kustomize deploy/k8s/overlays/prod | python3 scripts/check_namespace.py jobbot
Catches objects that silently land in "default" (e.g. Kustomize components added in an overlay
that has no `namespace:` field)."""
import sys

import yaml

expected = sys.argv[1]
bad = [
    f"{doc['kind']}/{doc['metadata']['name']}"
    for doc in yaml.safe_load_all(sys.stdin)
    if doc and doc["kind"] != "Namespace" and doc["metadata"].get("namespace") != expected
]
if bad:
    sys.exit(f"outside namespace {expected}: {', '.join(bad)}")
print(f"ok: all objects in namespace {expected}")

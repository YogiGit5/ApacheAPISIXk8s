#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  VZone Platform - Auth Setup (BYPASSED)"
echo "============================================"
echo ""
echo "  JWT authentication is currently DISABLED."
echo "  All routes accept unauthenticated requests."
echo ""
echo "  Planned: Keycloak OIDC integration"
echo "    Service → Keycloak /token → gets token"
echo "    → calls API with token → APISIX validates via openid-connect plugin"
echo ""
echo "  No consumers or JWT sign routes were created."
echo "============================================"

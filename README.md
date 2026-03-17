  Final Project Structure

  .
  ├── apisix/config.yaml          # APISIX config (used by Docker Compose)
  ├── docker-compose.yml          # Local dev (Docker)
  ├── k8s/
  │   ├── values.yaml             # APISIX Helm chart values
  │   └── httpbin.yaml            # Mock backend deployment + service
  ├── scripts/
  │   ├── dev-up.sh / dev-down.sh     # Docker Compose (local)
  │   ├── k8s-up.sh / k8s-down.sh    # Kubernetes (server)
  └── .gitignore

  ---
  Exact Steps on Your Ubuntu Server (K8s)

  Prerequisites — verify these are installed

  kubectl version --client       # K8s CLI
  helm version                   # Helm 3
  curl --version                 # for route setup

  Deploy — single command

  # Get the project
  git clone https://github.com/YogiGit5/ApacheAPISIX.git
  cd ApacheAPISIX

  # Make executable & run
  chmod +x scripts/k8s-up.sh scripts/k8s-down.sh
  bash scripts/k8s-up.sh

  What k8s-up.sh does (11 steps, fully automated)

  Step 1  → helm repo add apisix + bitnami
  Step 2  → kubectl create namespace apisix
  Step 3  → helm install apisix (includes etcd)
  Step 4  → kubectl apply httpbin mock backend
  Step 5  → Wait for all pods ready
  Step 6  → Port-forward Admin API (localhost:9180)
  Step 7  → Apply global rules (CORS, request-id)
  Step 8  → Apply upstreams → httpbin.apisix.svc.cluster.local:80
  Step 9  → Apply 5 routes (tracking R/W, notification R/W, websocket)
  Step 10 → Port-forward Gateway (localhost:9080)
  Step 11 → Health check

  Architecture on K8s

  ┌─ namespace: apisix ──────────────────────────────────┐
  │                                                       │
  │  ┌────────────┐   ┌──────────────┐   ┌────────────┐ │
  │  │  etcd pod  │◄──│  APISIX pod  │──►│  httpbin   │ │
  │  │  (Helm)    │   │  (Helm)      │   │  (mock)    │ │
  │  │  :2379     │   │  :9080 gw    │   │  :80       │ │
  │  │            │   │  :9180 admin │   │            │ │
  │  └────────────┘   └──────┬───────┘   └────────────┘ │
  │                          │                            │
  └──────────────────────────┼────────────────────────────┘
                             │ port-forward
                      ┌──────┴──────┐
                      │ localhost   │
                      │ :9080 (gw)  │
                      │ :9180 (adm) │
                      └─────────────┘

  Test

  # Tracking
  curl http://localhost:9080/api/v1/tracking/vehicles

  # Notifications
  curl -X POST http://localhost:9080/api/v1/notifications/send \
    -H "Content-Type: application/json" \
    -d '{"msg": "test"}'

  # Check pods
  kubectl get pods -n apisix

  # Check routes in APISIX
  curl -H "X-API-KEY: dev-admin-key" http://localhost:9180/apisix/admin/routes

  Tear Down

  bash scripts/k8s-down.sh

  ---
  When you swap httpbin for real services later

  Just update the upstream nodes in k8s-up.sh:

  # Change this:
  K8S_BACKEND="httpbin.apisix.svc.cluster.local:80"

  # To your real services:
  # K8S_BACKEND="live-tracking-service.vzone.svc.cluster.local:8080"

  Or re-apply individual upstreams via the Admin API curl commands.
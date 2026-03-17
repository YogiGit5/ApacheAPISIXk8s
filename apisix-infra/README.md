# VZone Platform - APISIX API Gateway Infrastructure

API Gateway infrastructure for the VZone platform, powered by Apache APISIX 3.9.x.

## Architecture

```
                           ┌──────────────────────────────────────────────┐
                           │              apisix namespace                │
                           │                                              │
    Internet / Clients     │   ┌──────────────────┐    ┌──────────┐      │
    ───────────────────────┼──►│  APISIX Gateway   │───►│  etcd    │      │
    :9080 (HTTP)           │   │  :9080  :9443     │    │  :2379   │      │
    :9443 (HTTPS)          │   │  :9180 (Admin)    │    └──────────┘      │
                           │   │  :9091 (Metrics)  │                      │
                           │   └────────┬─────────┘                      │
                           └────────────┼─────────────────────────────────┘
                                        │
                           ┌────────────┼─────────────────────────────────┐
                           │            │        vzone namespace            │
                           │            ▼                                 │
                           │   ┌─────────────────┐  ┌────────────────┐   │
                           │   │ Live Tracking    │  │ Trips Service  │   │
                           │   │ :8080 (REST+WS)  │  │ :8080 (REST)   │   │
                           │   └─────────────────┘  └────────────────┘   │
                           │   ┌─────────────────┐  ┌────────────────┐   │
                           │   │ Alert Config     │  │ Notification   │   │
                           │   │ :8080 (REST)      │  │ :8080 (REST)   │   │
                           │   └─────────────────┘  └────────────────┘   │
                           └──────────────────────────────────────────────┘
```

## Route Table

| Route | Method | Backend Service | Rate Limit | Description |
|-------|--------|-----------------|------------|-------------|
| `/api/v1/tracking/*` | GET | Live Tracking Service | 100 req/min per IP | Vehicle tracking reads |
| `/api/v1/tracking/*` | POST, PUT, PATCH, DELETE | Live Tracking Service | 20 req/min per IP | Vehicle tracking writes |
| `/ws/tracking` | GET (WebSocket) | Live Tracking Service | 50 concurrent/IP | Real-time tracking WebSocket |
| `/api/v1/notifications/*` | GET | Notification Service | 100 req/min per IP | Notification reads |
| `/api/v1/notifications/*` | POST, PUT, PATCH, DELETE | Notification Service | 20 req/min per IP | Notification writes |

### Load Balancing Strategy

| Upstream | Type | Reason |
|----------|------|--------|
| REST services | `roundrobin` | Even distribution across pods, stateless requests |
| WebSocket `/ws/tracking` | `chash` (consistent hash by `remote_addr`) | Sticky sessions — same client IP always connects to same pod, required for persistent WebSocket connections |

All upstreams include **active health checks** (periodic HTTP probes to `/healthz`) and **passive health checks** (monitors response codes, auto-removes unhealthy nodes).

### Rate Limiting

| Route Type | Plugin | Limit | Key | Rejected Code |
|------------|--------|-------|-----|---------------|
| REST read (GET) | `limit-count` | 100 req / 60s | `remote_addr` (client IP) | 429 |
| REST write (POST/PUT/PATCH/DELETE) | `limit-count` | 20 req / 60s | `remote_addr` (client IP) | 429 |
| WebSocket | `limit-conn` | 50 concurrent + 10 burst | `remote_addr` (client IP) | 429 |

- Rate limits are **per-node** (`policy: local`) in dev. For production multi-replica deployments, switch to `policy: redis` backed by Valkey/Redis to share counters across APISIX nodes (see `plugins/security/rate-limit.yaml` for config reference).
- Exceeded requests receive HTTP **429** with a JSON error body.

### Authentication

All API routes require a valid **JWT token** in the `Authorization: Bearer <token>` header.

| Consumer | Key | Token Expiry | Purpose |
|----------|-----|-------------|---------|
| `vzone_platform` | `vzone_platform_key` | 24 hours | Service-to-service communication |
| `vzone_admin` | `vzone_admin_key` | 1 hour | Admin operations |

**Generate a test token (dev only):**

```bash
curl http://localhost:9080/apisix/plugin/jwt/sign?key=vzone_platform_key
```

**Use the token:**

```bash
curl -H "Authorization: Bearer <token>" http://localhost:9080/api/v1/tracking/vehicles
```

### Global Rules (applied to all routes)

| Rule | Description |
|------|-------------|
| CORS | Allows cross-origin requests with standard headers |
| Request-ID | Generates UUID `X-Request-ID` header on every request |
| HTTP → HTTPS redirect | All HTTP requests are 301 redirected to HTTPS |

### HTTPS / TLS

| Environment | Certificate Source | Automation |
|-------------|-------------------|------------|
| Dev | Self-signed (generated via `openssl`) | `make ssl-dev` |
| Staging | Let's Encrypt (staging ACME) | `make ssl-prod` with cert-manager |
| Prod | Let's Encrypt (prod ACME) | `make ssl-prod` with cert-manager, auto-renewal |

Dev certificates include SANs for `localhost`, `*.localhost`, and `*.apisix.svc.cluster.local`.

### Logging & Monitoring

**Prometheus metrics** are exported on port `9091` at `/apisix/prometheus/metrics`.

| Metric | Description |
|--------|-------------|
| `apisix_http_status` | Request count by route, status code, and consumer |
| `apisix_http_latency_bucket` | Request latency histogram (p50, p90, p99) |
| `apisix_bandwidth` | Ingress/egress bytes per route |
| `apisix_upstream_status` | Upstream response status codes |
| `apisix_node_info` | APISIX node version and hostname |

**Access logging** via `http-logger` plugin sends structured JSON logs to an external HTTP collector (e.g., Fluentd, Loki, ClickHouse ingest). Enable by setting `HTTP_LOGGER_URI`:

```bash
HTTP_LOGGER_URI=http://collector:9080/logs make monitoring
```

**Kubernetes integration**: `ServiceMonitor` and `PodMonitor` CRDs are included for Prometheus Operator-based clusters.

## Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/) (v1.28+)
- [Helm](https://helm.sh/docs/intro/install/) (v3.12+)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/) (for dev) or GKE/EKS access (for prod)
- `python3` with `pyyaml` (`pip3 install pyyaml`)
- `openssl` (for dev certificate generation)
- `curl`

## Quick Start (Dev / Minikube)

```bash
# 1. Provision everything (etcd + APISIX + routes)
make dev-setup

# 2. Start port-forwarding
make port-forward

# 3. Configure JWT authentication
make auth

# 4. Re-apply routes (now with jwt-auth plugin)
make routes

# 5. Configure HTTPS (self-signed for dev)
make ssl

# 6. Enable Prometheus metrics
make monitoring

# 7. Verify health
make health

# 8. Run all tests
make test
```

## Environment-Specific Deployment

### Dev (Minikube)

```bash
make dev-setup     # 1 etcd replica, 1 APISIX replica, NodePort
make dev-teardown  # Clean up everything
```

### Staging

```bash
helm upgrade --install apisix-etcd bitnami/etcd \
  -n apisix --values helm/etcd/values-prod.yaml \
  --set replicaCount=2

helm upgrade --install apisix apisix/apisix \
  -n apisix --values helm/apisix/values-staging.yaml \
  --set admin.credentials.admin="$APISIX_ADMIN_KEY"

bash scripts/apply-routes.sh
```

### Prod (GKE / EKS)

```bash
export APISIX_ADMIN_KEY="your-secure-key-here"
bash scripts/setup-prod.sh   # 3 etcd replicas, 3 APISIX replicas, LoadBalancer
```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make dev-setup` | Provision APISIX on Minikube with all routes |
| `make dev-teardown` | Tear down the dev environment |
| `make routes` | Apply all route configurations |
| `make health` | Run health checks |
| `make test` | Run all tests (routing + WebSocket) |
| `make test-routing` | Run routing smoke tests only |
| `make test-ws` | Run WebSocket tests only |
| `make port-forward` | Start kubectl port-forwarding |
| `make auth` | Create JWT consumers and sign endpoint |
| `make test-auth` | Run JWT authentication tests |
| `make ssl` | Configure HTTPS (defaults to dev self-signed) |
| `make ssl-dev` | Generate self-signed certs + upload to APISIX |
| `make ssl-prod` | Let's Encrypt via cert-manager + upload to APISIX |
| `make test-ssl` | Run HTTPS / TLS tests |
| `make test-rate-limit` | Run rate limiting tests |
| `make monitoring` | Enable Prometheus metrics + optional HTTP logger |
| `make test-monitoring` | Run logging and monitoring tests |
| `make help` | Show all commands |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APISIX_ADMIN_URL` | `http://localhost:9180/apisix/admin` | Admin API URL |
| `APISIX_ADMIN_KEY` | `dev-admin-key` | Admin API key |
| `APISIX_GATEWAY_URL` | `http://localhost:9080` | Gateway URL |
| `APISIX_NAMESPACE` | `apisix` | Kubernetes namespace |
| `APISIX_ENV` | `dev` | Environment: dev, staging, or prod |
| `GATEWAY_DOMAIN` | `localhost` | Domain for TLS certificate |
| `ACME_EMAIL` | *(required for prod)* | Email for Let's Encrypt registration |
| `APISIX_METRICS_URL` | `http://localhost:9091/apisix/prometheus/metrics` | Prometheus metrics endpoint |
| `HTTP_LOGGER_URI` | *(optional)* | HTTP collector URI for access log shipping |
| `JWT_SECRET` | `vzone-dev-secret-change-in-prod` | JWT signing secret (platform consumer) |
| `JWT_SECRET_ADMIN` | `vzone-admin-secret-change-in-prod` | JWT signing secret (admin consumer) |

### Adding a New Route

1. Create upstream YAML in `routes/upstreams/`:

```yaml
_meta:
  resource: upstreams
  id: "5"

name: my-service-upstream
type: roundrobin
nodes:
  "my-service.vzone.svc.cluster.local:8080": 1
```

2. Create route YAML in `routes/routes/`:

```yaml
_meta:
  resource: routes
  id: "500"

name: my-service-routes
uri: /api/v1/my-resource/*
upstream_id: "5"
```

3. Apply: `make routes`

### Environment Differences

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| APISIX replicas | 1 | 2 | 3 |
| etcd replicas | 1 | 2 | 3 |
| Gateway type | NodePort | LoadBalancer | LoadBalancer |
| Admin API access | 0.0.0.0/0 | 10.0.0.0/8 | 10.0.0.0/8 |
| CPU request | 200m | 500m | 1 |
| Memory request | 256Mi | 512Mi | 1Gi |

## Project Structure

```
apisix-infra/
├── README.md                              # This file
├── Makefile                               # All commands
├── k8s/
│   ├── namespace.yaml                     # apisix namespace
│   ├── network-policy.yaml                # Pod network restrictions
│   ├── servicemonitor.yaml                # Prometheus Operator ServiceMonitor
│   └── podmonitor-etcd.yaml               # etcd PodMonitor for Prometheus
├── helm/
│   ├── apisix/
│   │   ├── values-dev.yaml                # Minikube (1 replica, NodePort)
│   │   ├── values-staging.yaml            # Staging (2 replicas, LB)
│   │   └── values-prod.yaml               # Prod (3 replicas, LB)
│   └── etcd/
│       ├── values-dev.yaml                # 1 replica, 2Gi storage
│       └── values-prod.yaml               # 3 replicas, 10Gi, anti-affinity
├── routes/
│   ├── upstreams/                         # Backend service definitions
│   │   ├── live-tracking.yaml
│   │   ├── live-tracking-ws.yaml
│   │   └── notification.yaml
│   ├── routes/                            # URL → upstream mappings
│   │   ├── tracking-routes.yaml           # Tracking reads (GET, 100/min)
│   │   ├── tracking-write-routes.yaml     # Tracking writes (POST/PUT/PATCH/DELETE, 20/min)
│   │   ├── notification-routes.yaml       # Notification reads (GET, 100/min)
│   │   ├── notification-write-routes.yaml # Notification writes (20/min)
│   │   └── websocket-routes.yaml          # WebSocket (50 concurrent/IP)
│   └── global-rules/                      # Applied to all routes
│       ├── cors.yaml
│       └── request-id.yaml
├── plugins/
│   ├── auth/
│   │   └── jwt-auth.yaml                  # JWT consumer + plugin config
│   ├── security/
│   │   ├── tls-redirect.yaml              # HTTP → HTTPS global redirect rule
│   │   ├── rate-limit.yaml                # Rate limiting reference (local + redis config)
│   │   └── ip-restriction.yaml            # IP allow/block list reference
│   └── observability/
│       ├── prometheus.yaml                # Prometheus metrics global rule
│       ├── logging.yaml                   # HTTP logger global rule (external collector)
│       └── access-log-format.yaml         # Structured log format reference
├── ssl/
│   ├── dev/
│   │   ├── self-signed-cert.sh            # Generates CA + server cert with SANs
│   │   └── certs/                         # Generated certs (.gitignored)
│   └── prod/
│       └── cert-manager.yaml              # Let's Encrypt ClusterIssuer + Certificate
├── scripts/
│   ├── setup-dev.sh                       # Full dev provisioning
│   ├── setup-prod.sh                      # Full prod deployment
│   ├── apply-routes.sh                    # Apply all YAML route configs
│   ├── apply-auth.sh                      # Create JWT consumers + sign endpoint
│   ├── apply-ssl.sh                       # TLS cert generation/upload (dev + prod)
│   ├── apply-monitoring.sh                # Prometheus + HTTP logger setup
│   ├── health-check.sh                    # Infrastructure health
│   └── test-routes.sh                     # Route smoke tests
└── tests/
    ├── test-routing.sh                    # Routing validation
    ├── test-websocket.sh                  # WebSocket tests
    ├── test-load-balancing.sh             # LB strategy verification
    ├── test-auth.sh                       # JWT auth enforcement tests
    ├── test-ssl.sh                        # HTTPS / TLS verification tests
    ├── test-rate-limit.sh                 # Rate limit tests
    └── test-monitoring.sh                 # Prometheus and logging tests
```


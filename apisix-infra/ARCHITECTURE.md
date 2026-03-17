# VZone Platform - APISIX Architecture Deep Dive

## What is an API Gateway?

An API Gateway is a server that sits between clients and your backend services. Every request enters through the gateway first. Think of it as a security checkpoint + traffic controller at the entrance of a building.

```
Without Gateway                      With Gateway
──────────────                       ────────────
Client ──► Tracking Service          Client ──► APISIX ──► Tracking Service
Client ──► Notification Service                        ──► Notification Service
Client ──► Future Service X                            ──► Future Service X

Problems:                            Solved:
- Client knows every service URL     - Single URL for everything
- Each service handles auth          - Auth handled once at gateway
- No centralized rate limiting       - Rate limits at gateway
- No unified logging                 - All requests logged centrally
- SSL certs per service              - SSL terminates at gateway
```

---

## Why Apache APISIX?

APISIX is built on top of NGINX (via OpenResty + Lua). It processes requests at near-NGINX speed but adds dynamic configuration — you can add routes, change plugins, update upstreams at runtime without restarting anything.

```
┌───────────────────────────────────────────┐
│              Apache APISIX                │
│                                           │
│  ┌─────────────────────────────────────┐  │
│  │           NGINX (OpenResty)         │  │  ← Raw HTTP performance
│  │  ┌──────────────────────────────┐   │  │
│  │  │        Lua Plugins           │   │  │  ← Dynamic logic (auth, rate limit, etc.)
│  │  └──────────────────────────────┘   │  │
│  └─────────────────────────────────────┘  │
│                                           │
│  ┌──────────┐                             │
│  │ Admin API │  ← REST API to configure   │
│  └──────┬───┘    routes/plugins at runtime│
│         │                                 │
│  ┌──────▼───┐                             │
│  │   etcd   │  ← Stores all config       │
│  └──────────┘    (survives restarts)      │
└───────────────────────────────────────────┘
```

**etcd** is a distributed key-value store. When you create a route via the Admin API, APISIX writes it to etcd. If APISIX restarts, it reads everything back from etcd. Nothing is lost.

---

## Project Structure Explained

```
apisix-infra/
│
├── k8s/                          KUBERNETES MANIFESTS
│   ├── namespace.yaml            ← Isolated "apisix" namespace
│   ├── network-policy.yaml       ← Firewall: who can talk to whom
│   ├── servicemonitor.yaml       ← Tells Prometheus to scrape APISIX
│   └── podmonitor-etcd.yaml      ← Tells Prometheus to scrape etcd
│
├── helm/                         DEPLOYMENT CONFIGURATION
│   ├── apisix/
│   │   ├── values-dev.yaml       ← 1 replica, 256Mi, NodePort
│   │   ├── values-staging.yaml   ← 2 replicas, 512Mi, LoadBalancer
│   │   └── values-prod.yaml      ← 3 replicas, 1Gi, LoadBalancer, restricted admin
│   └── etcd/
│       ├── values-dev.yaml       ← 1 replica, 2Gi disk
│       └── values-prod.yaml      ← 3 replicas, 10Gi, anti-affinity
│
├── routes/                       TRAFFIC RULES
│   ├── upstreams/                ← WHERE backends are
│   ├── routes/                   ← WHICH requests go WHERE
│   └── global-rules/             ← Rules for EVERY request
│
├── plugins/                      PLUGIN CONFIGURATIONS
│   ├── auth/                     ← JWT authentication
│   ├── security/                 ← Rate limiting, TLS redirect, IP restriction
│   └── observability/            ← Prometheus, logging
│
├── ssl/                          CERTIFICATES
│   ├── dev/                      ← Self-signed (openssl)
│   └── prod/                     ← Let's Encrypt (cert-manager)
│
├── scripts/                      AUTOMATION
│   ├── lib.sh                    ← Shared helpers (Python detection, path conversion)
│   ├── setup-dev.sh              ← One command: namespace + etcd + APISIX + routes
│   ├── setup-prod.sh             ← Production deployment with safety prompts
│   ├── apply-routes.sh           ← Reads YAML files → PUTs to Admin API
│   ├── apply-auth.sh             ← Creates JWT consumers + sign endpoint
│   ├── apply-ssl.sh              ← Generates/uploads TLS certificates
│   ├── apply-monitoring.sh       ← Enables Prometheus + optional HTTP logger
│   ├── health-check.sh           ← Verifies all components are running
│   └── test-routes.sh            ← Sends requests to verify routing
│
├── tests/                        VERIFICATION
│   ├── test-routing.sh           ← Are routes forwarding correctly?
│   ├── test-websocket.sh         ← Does WebSocket upgrade work?
│   ├── test-load-balancing.sh    ← Is chash on WS, roundrobin on REST?
│   ├── test-auth.sh              ← Does 401 without token, 200 with token?
│   ├── test-ssl.sh               ← Is HTTPS working, HTTP redirecting?
│   ├── test-rate-limit.sh        ← Does 429 fire after limit exceeded?
│   └── test-monitoring.sh        ← Are Prometheus metrics being collected?
│
├── Makefile                      ← Single entry point for all commands
└── README.md                     ← Setup guide, route table, env vars
```

---

## Core Concepts

### 1. Upstream (WHERE is the backend?)

An upstream defines the address, load balancing strategy, and health checks for a backend service.

```yaml
# routes/upstreams/live-tracking.yaml

name: live-tracking-upstream
type: roundrobin                    ← Load balancing strategy
nodes:
  "live-tracking-service.vzone.svc.cluster.local:8080": 1    ← Backend address + weight
retries: 2                          ← Retry on failure
timeout:
  connect: 5                        ← Seconds to wait for TCP connection
  send: 5                           ← Seconds to wait sending request
  read: 10                          ← Seconds to wait for response
checks:
  active:                           ← APISIX probes the backend periodically
    http_path: /healthz
    healthy:
      interval: 5                   ← Probe every 5 seconds
      successes: 2                  ← Mark healthy after 2 successful probes
    unhealthy:
      http_failures: 3              ← Mark unhealthy after 3 failed probes
  passive:                          ← APISIX watches real traffic responses
    unhealthy:
      http_statuses: [500, 502, 503]  ← These status codes = unhealthy
```

**Why?** Separating upstream from route means multiple routes can share one upstream. If the backend address changes, update one file — not every route.

### 2. Route (WHICH requests go WHERE?)

A route maps a URL pattern + HTTP method to an upstream, with plugins attached.

```yaml
# routes/routes/tracking-routes.yaml

name: tracking-read-routes
uri: /api/v1/tracking/*             ← Match any path under /api/v1/tracking/
methods: [GET]                       ← Only GET requests
upstream_id: "1"                     ← Forward to upstream 1 (live-tracking)
plugins:
  jwt-auth: {}                       ← Require valid JWT token
  limit-count:                       ← Rate limit: 100 requests per minute per IP
    count: 100
    time_window: 60
    key: remote_addr
    rejected_code: 429
  proxy-rewrite:                     ← Rewrite URI before forwarding
    regex_uri:
      - "^/api/v1/tracking/(.*)"
      - "/api/v1/tracking/$1"
```

**Why split read/write routes?** Different rate limits. GET (read) = 100/min, POST/PUT/DELETE (write) = 20/min. Writes are more expensive for the backend.

### 3. Global Rule (applies to ALL requests)

Global rules run on every request regardless of which route matches.

```yaml
# routes/global-rules/cors.yaml
plugins:
  cors:
    allow_origins: "*"
    allow_methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS"

# routes/global-rules/request-id.yaml
plugins:
  request-id:
    header_name: "X-Request-ID"
    include_in_response: true
    algorithm: "uuid"
```

| Global Rule | ID | Purpose |
|-------------|-----|---------|
| CORS | 1 | Allows browsers to call the API from different domains |
| Request-ID | 2 | Unique UUID per request for tracing across services |
| HTTP→HTTPS redirect | 3 | Forces all traffic to HTTPS |
| Prometheus | 4 | Records metrics for every request |
| HTTP Logger | 5 | Ships access logs to external collector (optional) |

### 4. Consumer (WHO is making the request?)

A consumer represents an authenticated identity (a service account, a user role, etc.).

```yaml
username: vzone_platform
plugins:
  jwt-auth:
    key: vzone_platform_key          ← Identifier in the JWT
    secret: "..."                     ← Used to sign/verify the token
    algorithm: HS256
    exp: 86400                        ← Token expires in 24 hours
```

**Why consumers?** Different consumers can have different permissions, rate limits, or access levels. Prometheus metrics tag every request with the consumer name for per-consumer monitoring.

### 5. Plugin (WHAT happens to the request?)

Plugins are the building blocks. Each plugin does one thing. You stack them on routes or global rules.

```
Request arrives
    │
    ▼
┌─────────────────────────────────────────────┐
│ Plugin Chain (executed in order)             │
│                                             │
│  1. jwt-auth        → Is the token valid?   │
│                        No → 401, stop       │
│                        Yes → continue       │
│                                             │
│  2. limit-count     → Under rate limit?     │
│                        No → 429, stop       │
│                        Yes → continue       │
│                                             │
│  3. proxy-rewrite   → Modify URI/headers    │
│                        before forwarding     │
│                                             │
│  4. [forward to upstream]                   │
│                                             │
│  5. cors            → Add CORS headers      │
│                        to response          │
│                                             │
│  6. request-id      → Add X-Request-ID      │
│                        to response          │
│                                             │
│  7. prometheus      → Record metrics        │
│                        (status, latency)    │
└─────────────────────────────────────────────┘
    │
    ▼
Response sent to client
```

Plugins used in this project:

| Plugin | Type | Where Applied | What It Does |
|--------|------|---------------|-------------|
| `jwt-auth` | Authentication | Per route | Validates JWT token, identifies consumer |
| `limit-count` | Security | Per route | Max N requests per time window per IP |
| `limit-conn` | Security | WebSocket route | Max concurrent connections per IP |
| `proxy-rewrite` | Traffic | Per route | Rewrites URI path before forwarding |
| `cors` | Traffic | Global rule | Adds Cross-Origin headers |
| `request-id` | Traffic | Global rule | Generates unique request UUID |
| `redirect` | Traffic | Global rule | HTTP → HTTPS 301 redirect |
| `prometheus` | Observability | Global rule | Exports request metrics |
| `http-logger` | Observability | Global rule | Ships JSON access logs to collector |
| `public-api` | Utility | JWT sign route | Exposes internal API (token signing) |

---

## Request Lifecycle — Complete Flow

### REST Request: `GET /api/v1/tracking/vehicles`

```
Client
  │
  │  GET https://gateway:9443/api/v1/tracking/vehicles
  │  Authorization: Bearer eyJ0eXAiOiJKV1Q...
  │
  ▼
┌──────────────────────────────────────────────────────┐
│                   APISIX Gateway                     │
│                                                      │
│  ┌─ TLS TERMINATION ──────────────────────────────┐  │
│  │ Decrypt HTTPS using server.crt/server.key      │  │
│  │ Internal processing continues in plain HTTP    │  │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
│  ┌─ GLOBAL RULES ────▼───────────────────────────┐   │
│  │ ① request-id  → Generate X-Request-ID: abc-123│   │
│  │ ② cors        → Prepare CORS response headers │   │
│  │ ③ redirect    → HTTP? 301 to HTTPS. Skip.     │   │
│  │ ④ prometheus  → Start timer for latency        │   │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
│  ┌─ ROUTE MATCHING ──▼───────────────────────────┐   │
│  │ URI: /api/v1/tracking/vehicles                │   │
│  │ Method: GET                                    │   │
│  │                                                │   │
│  │ Check routes in order:                         │   │
│  │   Route 100: uri=/api/v1/tracking/* + GET ✅   │   │
│  │   → MATCHED                                    │   │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
│  ┌─ ROUTE PLUGINS ───▼───────────────────────────┐   │
│  │                                                │   │
│  │ ① jwt-auth                                     │   │
│  │   Parse Authorization header                   │   │
│  │   Decode JWT: { key: "vzone_platform_key" }    │   │
│  │   Look up consumer by key → vzone_platform     │   │
│  │   Verify signature with consumer's secret      │   │
│  │   Check expiry: not expired ✅                 │   │
│  │   → Attach consumer to request context         │   │
│  │                                                │   │
│  │ ② limit-count                                  │   │
│  │   Key: remote_addr (client IP: 192.168.1.10)   │   │
│  │   Counter: 47 / 100 in current 60s window      │   │
│  │   Under limit ✅ → Increment to 48             │   │
│  │                                                │   │
│  │ ③ proxy-rewrite                                │   │
│  │   regex: ^/api/v1/tracking/(.*) → /$1          │   │
│  │   /api/v1/tracking/vehicles → /api/v1/tracking/vehicles │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
│  ┌─ UPSTREAM ────────▼───────────────────────────┐   │
│  │ upstream_id: 1 (live-tracking-upstream)        │   │
│  │ type: roundrobin                               │   │
│  │                                                │   │
│  │ Nodes:                                         │   │
│  │   pod-1 (10.0.0.5:8080) weight=1 HEALTHY ✅   │   │
│  │   pod-2 (10.0.0.6:8080) weight=1 HEALTHY ✅   │   │
│  │   pod-3 (10.0.0.7:8080) weight=1 UNHEALTHY ❌ │   │
│  │                                                │   │
│  │ Select: pod-1 (round-robin turn)               │   │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
│                      ▼                               │
│              Forward request to                      │
│              10.0.0.5:8080                           │
│              GET /api/v1/tracking/vehicles            │
│                      │                               │
│                      ▼                               │
│              Backend responds: 200 OK                │
│              Body: { "vehicles": [...] }             │
│                      │                               │
│  ┌─ RESPONSE ────────▼───────────────────────────┐   │
│  │ Add headers:                                   │   │
│  │   X-Request-ID: abc-123                        │   │
│  │   Access-Control-Allow-Origin: *               │   │
│  │   Access-Control-Allow-Methods: GET, POST...   │   │
│  │                                                │   │
│  │ Prometheus records:                            │   │
│  │   apisix_http_status{code="200",               │   │
│  │     route="tracking-read-routes",              │   │
│  │     consumer="vzone_platform"} +1              │   │
│  │   apisix_http_latency{...} 12ms                │   │
│  │   apisix_bandwidth{type="egress"} +1247 bytes  │   │
│  └────────────────────────────────────────────────┘  │
│                      │                               │
└──────────────────────┼───────────────────────────────┘
                       │
                       ▼
                  Client receives
                  HTTP 200 + JSON + headers
```

### WebSocket Request: `GET /ws/tracking`

```
Client
  │
  │  GET wss://gateway:9443/ws/tracking
  │  Connection: Upgrade
  │  Upgrade: websocket
  │  Authorization: Bearer eyJ0eXAi...
  │
  ▼
APISIX Gateway
  │
  ├─ TLS termination
  ├─ Global rules (request-id, prometheus)
  │
  ├─ Route match: /ws/tracking → Route 101
  │
  ├─ jwt-auth → Validate token ✅
  ├─ limit-conn → 12/50 concurrent connections ✅
  │
  ├─ Upstream 5 (live-tracking-ws-upstream)
  │   type: chash (consistent hash)
  │   hash_on: vars
  │   key: remote_addr
  │   │
  │   │  Hash(192.168.1.10) → always maps to pod-2
  │   │  (same client IP = same pod = sticky session)
  │   │
  │   └─► pod-2 (10.0.0.6:8080)
  │
  ├─ HTTP 101 Switching Protocols
  │
  └─ Persistent bidirectional connection
     Client ◄──────────────────► Backend pod-2
             real-time messages
             (location updates, alerts)
```

**Why consistent hash for WebSocket?**
WebSocket connections are stateful — the server maintains connection state in memory. If a reconnecting client hits a different pod, it loses its session context. Consistent hashing by client IP guarantees the same client always reaches the same pod.

---

## Load Balancing Strategies

```
Round-Robin (REST routes)                 Consistent Hash (WebSocket)
─────────────────────────                 ──────────────────────────

Request 1 ──► Pod A                       Client IP 10.0.0.1 ──► Pod B (always)
Request 2 ──► Pod B                       Client IP 10.0.0.2 ──► Pod A (always)
Request 3 ──► Pod C                       Client IP 10.0.0.3 ──► Pod C (always)
Request 4 ──► Pod A  (cycles back)        Client IP 10.0.0.1 ──► Pod B (same!)

Good for: stateless REST APIs             Good for: stateful WebSocket connections
Each request is independent               Same client must reach same server
```

---

## Rate Limiting — How It Works

```
Timeline (60-second window)
──────────────────────────────────────────────────────────────────►

IP: 192.168.1.10 hitting POST /api/v1/tracking/vehicles (limit: 20/min)

Request 1  ✅ (1/20)
Request 2  ✅ (2/20)
Request 3  ✅ (3/20)
  ...
Request 19 ✅ (19/20)
Request 20 ✅ (20/20)
Request 21 ❌ 429 Too Many Requests  {"error": "Rate limit exceeded", "retry_after": 60}
Request 22 ❌ 429
  ...
  [60 seconds pass, window resets]
Request 23 ✅ (1/20)  ← new window
```

| Route Type | Plugin | Limit | Why |
|------------|--------|-------|-----|
| REST read (GET) | `limit-count` | 100/min per IP | Reads are cheap, allow more |
| REST write (POST/PUT/PATCH/DELETE) | `limit-count` | 20/min per IP | Writes are expensive, protect backend |
| WebSocket | `limit-conn` | 50 concurrent per IP | Prevent one client from hogging all connections |

**Dev vs Prod rate limiting:**
- Dev: `policy: local` — each APISIX node counts independently
- Prod: `policy: redis` — all APISIX nodes share a counter via Valkey/Redis

---

## JWT Authentication Flow

```
Step 1: Get a token
──────────────────
Client ──► GET /apisix/plugin/jwt/sign?key=vzone_platform_key
                                              │
APISIX looks up consumer with key             │
  → Found: vzone_platform                     │
  → Secret: vzone-dev-secret-...              │
  → Algorithm: HS256                          │
  → Expiry: 86400 seconds (24 hours)          │
                                              │
  Signs JWT:                                  │
  Header:  {"typ":"JWT","alg":"HS256"}        │
  Payload: {"key":"vzone_platform_key",       │
            "exp":1773760133}                 │
  Signature: HMAC-SHA256(header.payload,      │
             secret)                          │
                                              ▼
Client ◄── eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJrZXkiOiJ2em9...


Step 2: Use the token
─────────────────────
Client ──► GET /api/v1/tracking/vehicles
           Authorization: Bearer eyJ0eXAi...
                                              │
APISIX jwt-auth plugin:                       │
  1. Extract token from Authorization header  │
  2. Decode header → algorithm = HS256        │
  3. Decode payload → key = vzone_platform_key│
  4. Look up consumer by key                  │
  5. Verify signature using consumer's secret │
  6. Check exp > current time                 │
  7. All valid ✅ → attach consumer context   │
                                              ▼
  Request continues to upstream with consumer = vzone_platform


Step 3: What happens when auth fails
─────────────────────────────────────
No token         → 401 {"message":"Missing JWT token in request"}
Expired token    → 401 {"message":"failed to verify jwt"}
Wrong secret     → 401 {"message":"failed to verify jwt"}
Invalid format   → 401 {"message":"JWT token invalid"}
```

---

## HTTPS / TLS Flow

```
Dev Environment (self-signed)
─────────────────────────────

  make ssl
    │
    ├─ openssl generates:
    │    CA key (4096-bit) + CA cert
    │    Server key (2048-bit) + Server cert
    │    SANs: localhost, *.localhost, *.apisix.svc.cluster.local
    │
    ├─ Creates K8s TLS secret: apisix-gateway-tls
    │
    └─ Uploads cert+key to APISIX Admin API:
         PUT /apisix/admin/ssls/1
         { cert: "...", key: "...", snis: ["localhost", ...] }


Prod Environment (Let's Encrypt)
────────────────────────────────

  make ssl-prod
    │
    ├─ Installs cert-manager (if not present)
    │
    ├─ Creates ClusterIssuer:
    │    letsencrypt-prod (ACME v2)
    │    solver: HTTP-01 challenge
    │
    ├─ Creates Certificate CR:
    │    domain: $GATEWAY_DOMAIN
    │    auto-renew: 15 days before expiry
    │
    └─ cert-manager handles:
         DNS validation → Let's Encrypt issues cert
         Stores in K8s secret → Script uploads to APISIX


HTTP → HTTPS Redirect (Global Rule)
────────────────────────────────────

  Client: GET http://gateway/api/v1/tracking/vehicles
    │
    APISIX redirect plugin:
    │  http_to_https: true
    │
    ▼
  Client receives: 301 Moved Permanently
  Location: https://gateway/api/v1/tracking/vehicles
    │
    Client retries over HTTPS
    ▼
  Normal HTTPS flow continues
```

---

## Observability — What You Can See

### Prometheus Metrics (port 9091)

```
http://localhost:9091/apisix/prometheus/metrics
```

| Metric | What It Tells You |
|--------|------------------|
| `apisix_http_status{code, route, consumer}` | Request count per status code, route, and consumer |
| `apisix_http_latency_bucket{type, route}` | Latency distribution (p50, p90, p99) |
| `apisix_bandwidth{type, route}` | Bytes in (ingress) and out (egress) per route |
| `apisix_upstream_status{code, upstream}` | Backend response codes (spot backend failures) |
| `apisix_etcd_reachable` | 1 = etcd connected, 0 = config store down |
| `apisix_node_info` | APISIX version and hostname |

### Access Logs

```bash
docker logs -f apisix-gateway      # All logs (live)
docker logs apisix-gateway 2>&1    # Stdout + stderr
```

Log format per request:
```
client_ip - - [timestamp] "METHOD URI HTTP/1.1" status bytes latency "user-agent"
```

### HTTP Logger (optional, for production)

Ships structured JSON logs to an external collector (Fluentd, Loki, ClickHouse):

```json
{
  "client_ip": "192.168.1.10",
  "request": {
    "method": "GET",
    "uri": "/api/v1/tracking/vehicles",
    "headers": { "authorization": "Bearer ey..." }
  },
  "response": { "status": 200 },
  "upstream": { "addr": "10.0.0.5:8080", "status": 200 },
  "route": { "id": "100", "name": "tracking-read-routes" },
  "consumer": { "username": "vzone_platform" },
  "latency": 12,
  "start_time": 1773673733
}
```

Enable with: `HTTP_LOGGER_URI=http://collector:9080/logs make monitoring`

---

## Environment Differences

```
                    Dev (Minikube)      Staging             Prod (GKE/EKS)
                    ──────────────      ───────             ──────────────
APISIX replicas     1                   2                   3
etcd replicas       1                   2                   3
Gateway type        NodePort            LoadBalancer        LoadBalancer
Admin API access    0.0.0.0/0 (open)    10.0.0.0/8          10.0.0.0/8
TLS certificate     Self-signed         Let's Encrypt       Let's Encrypt
Rate limit policy   local (per-node)    local               redis (shared)
Prometheus          Metrics only        ServiceMonitor      ServiceMonitor
CPU request         200m                500m                1 core
Memory request      256Mi               512Mi               1Gi
etcd storage        2Gi                 5Gi                 10Gi
```

---

## How Configs Flow from YAML to APISIX

```
YAML files (routes/upstreams/*.yaml)
    │
    │  Each file has _meta section:
    │    _meta:
    │      resource: upstreams    ← API resource type
    │      id: "1"                ← Resource ID
    │
    ▼
scripts/apply-routes.sh
    │
    │  For each YAML file:
    │    1. Python reads YAML
    │    2. Extracts _meta (resource type + ID)
    │    3. Removes _meta from payload
    │    4. Converts remaining YAML to JSON
    │    5. curl -X PUT /apisix/admin/{resource}/{id}
    │
    ▼
APISIX Admin API (port 9180)
    │
    │  Validates the payload against schema
    │  Stores in etcd under /apisix/{resource}/{id}
    │
    ▼
etcd (port 2379)
    │
    │  Persistent key-value storage
    │  APISIX watches for changes in real-time
    │
    ▼
APISIX Gateway (port 9080)
    │
    │  Picks up new/updated config immediately
    │  No restart needed
    │
    ▼
Next request uses the new configuration
```

---

## Makefile — Command Reference

```bash
make dev-setup        # Full provisioning: namespace + etcd + APISIX + routes
make dev-teardown     # Delete everything
make routes           # Apply all route YAML configurations
make auth             # Create JWT consumers + sign endpoint
make ssl              # Generate and upload TLS certificates (dev)
make ssl-prod         # Let's Encrypt via cert-manager (prod)
make monitoring       # Enable Prometheus metrics + HTTP logger
make health           # Check all components are running
make test             # Run all test suites
make port-forward     # kubectl port-forward for local access
make help             # Show all available commands
```

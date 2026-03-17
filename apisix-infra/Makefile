.PHONY: dev-setup dev-teardown routes auth ssl ssl-dev ssl-prod monitoring health test \
       port-forward test-ws test-routing test-lb test-auth test-ssl test-rate-limit test-monitoring

NAMESPACE     := apisix
APISIX_RELEASE := apisix
ETCD_RELEASE   := apisix-etcd

# ─── Infrastructure & Routing ────────────────────────────

dev-setup: ## Provision APISIX on Minikube with routes
	@bash scripts/setup-dev.sh

dev-teardown: ## Tear down the dev environment
	@echo "==> Tearing down APISIX dev environment..."
	helm uninstall $(APISIX_RELEASE) -n $(NAMESPACE) 2>/dev/null || true
	helm uninstall $(ETCD_RELEASE) -n $(NAMESPACE) 2>/dev/null || true
	kubectl delete namespace $(NAMESPACE) 2>/dev/null || true
	@echo "==> Done."

routes: ## Apply all route configurations
	@bash scripts/apply-routes.sh

health: ## Run health checks
	@bash scripts/health-check.sh

test: test-routing test-ws test-lb test-auth test-ssl test-rate-limit test-monitoring ## Run all tests

test-routing: ## Run routing smoke tests
	@bash scripts/test-routes.sh

test-ws: ## Run WebSocket tests
	@bash tests/test-websocket.sh

port-forward: ## Start port-forwarding for local access
	@echo "Starting port-forwards (background)..."
	@kubectl port-forward svc/$(APISIX_RELEASE)-gateway -n $(NAMESPACE) 9080:9080 &
	@kubectl port-forward svc/$(APISIX_RELEASE)-admin -n $(NAMESPACE) 9180:9180 &
	@echo "Gateway:  http://localhost:9080"
	@echo "Admin:    http://localhost:9180"

# ─── Load Balancing ──────────────────────────────────────

test-lb: ## Verify load balancing and health check config
	@bash tests/test-load-balancing.sh

# ─── Authentication ──────────────────────────────────────

auth: ## Auth bypassed – will use Keycloak OIDC (prints info only)
	@bash scripts/apply-auth.sh

test-auth: ## Auth tests skipped – JWT removed, Keycloak pending
	@echo "Auth tests skipped: JWT removed. Will be replaced by Keycloak OIDC tests."

# ─── HTTPS / SSL ─────────────────────────────────────────

ssl: ssl-dev ## Configure SSL (defaults to dev)

ssl-dev: ## Generate self-signed certs and configure HTTPS (dev)
	@APISIX_ENV=dev bash scripts/apply-ssl.sh

ssl-prod: ## Configure Let's Encrypt certs via cert-manager (prod)
	@APISIX_ENV=prod bash scripts/apply-ssl.sh

test-ssl: ## Run HTTPS / TLS tests
	@bash tests/test-ssl.sh

# ─── Rate Limiting ───────────────────────────────────────

test-rate-limit: ## Run rate limiting tests
	@bash tests/test-rate-limit.sh

# ─── Logging & Monitoring ────────────────────────────────

monitoring: ## Enable Prometheus metrics and access logging
	@bash scripts/apply-monitoring.sh

test-monitoring: ## Run logging and monitoring tests
	@bash tests/test-monitoring.sh

# ─── Help ────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

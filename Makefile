WEB_CONFIG ?= imagekit-web/scripts/config.json
BACKEND_CONFIG ?= imagekit-backend/scripts/config.json

.PHONY: install install-web install-backend

install: install-backend install-web

install-web:
	@echo "=== Pulling latest imagekit-web ==="
	cd imagekit-web && git pull
	@echo "=== Installing imagekit-web ==="
	cd imagekit-web && sudo ./scripts/install.sh --config $(abspath $(WEB_CONFIG)) $(ARGS)

install-backend:
	@echo "=== Pulling latest imagekit-backend ==="
	cd imagekit-backend && git pull
	@echo "=== Installing imagekit-backend ==="
	cd imagekit-backend && sudo ./scripts/install.sh --config $(abspath $(BACKEND_CONFIG)) $(ARGS)

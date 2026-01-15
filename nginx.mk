# --- global settings ---
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
SHELL := /bin/bash

# --- recursive make commands ---
SELF := $(lastword $(MAKEFILE_LIST))
SUBMAKE := $(MAKE) --no-print-directory -f $(SELF)

# --- Nginx paths ---
NGINXDIR   ?= /etc/nginx
NGINX_MAIN ?= $(NGINXDIR)/nginx.conf
CONFD      ?= $(NGINXDIR)/conf.d
STREAMD    ?= $(NGINXDIR)/stream.conf.d

# Files in this repo
CONF_SRC_DIR     ?= conf
CONF_JSON_SRC    ?= $(CONF_SRC_DIR)/json_stream.conf
CONF_UDP_SRC     ?= $(CONF_SRC_DIR)/nginx-roughtime.conf

# Destination paths
CONF_JSON_DEST   ?= $(STREAMD)/00-json_stream_log.conf
CONF_STREAM_DEST ?= $(STREAMD)/roughtime.conf

# -----------------------------------------------------------------------------
# Help
.PHONY: help
help: ## Show this help
	@printf "\n\033[1mNginx (stream/UDP) targets\033[0m\n"
	@awk 'BEGIN{FS=":.*##"; OFS=""} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# -----------------------------------------------------------------------------

.PHONY: nginx-bootstrap nginx nginx-streamdir nginx-check-stream-include \
nginx-jsonlog nginx-udp nginx-enable nginx-test nginx-clean

nginx-bootstrap: ## Install stream include prereqs, JSON log, UDP conf, enable, and test
	$(SUBMAKE) nginx-streamdir
	$(SUBMAKE) nginx-check-stream-include
	$(SUBMAKE) nginx-jsonlog
	$(SUBMAKE) nginx-udp
	$(SUBMAKE) nginx-enable
	$(SUBMAKE) nginx-test

nginx: nginx-bootstrap ## Alias for nginx-bootstrap

nginx-streamdir: ## Create $(STREAMD) if missing
	@echo ">> Ensuring stream directory: $(STREAMD)"
	sudo install -d -m 0755 $(STREAMD)

nginx-check-stream-include: ## Verify nginx.conf includes stream{} or stream.conf.d/*.conf
	@echo ">> Checking for 'stream' include in $(NGINX_MAIN)"
	if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' $(NGINX_MAIN) || \
	   grep -Eq 'include[[:space:]]+/etc/nginx/stream\.conf\.d/\*\.conf;' $(NGINX_MAIN); then
	    echo "   OK: stream context is present"
	else
	    echo "ERROR: No 'stream { ... }' block found in $(NGINX_MAIN)"
	    echo "Please add the following outside your http block:"
	    echo ""
	    echo "stream {"
	    echo "    include $(STREAMD)/*.conf;"
	    echo "}"
	    echo ""
	    exit 1
	fi

nginx-jsonlog: ## Install stream JSON log format -> $(CONF_JSON_DEST)
	@echo ">> Installing JSON stream log -> $(CONF_JSON_DEST)"
	sudo install -D -m 0644 $(CONF_JSON_SRC) $(CONF_JSON_DEST)

nginx-udp: ## Install UDP RoughTime conf -> $(CONF_STREAM_DEST)
	@echo ">> Installing UDP RoughTime conf -> $(CONF_STREAM_DEST)"
	sudo install -D -m 0644 $(CONF_UDP_SRC) $(CONF_STREAM_DEST)

nginx-enable: ## Enable and start nginx (idempotent)
	@echo ">> Enabling and starting nginx..."
	sudo systemctl enable --now nginx || true

nginx-test: ## Validate nginx config and reload if valid
	@echo ">> Validating and reloading Nginx..."
	sudo nginx -t
	sudo systemctl reload nginx

nginx-clean: ## Remove installed stream configs (does not edit nginx.conf)
	@echo ">> Removing stream configs..."
	sudo rm -f "$(CONF_JSON_DEST)" "$(CONF_STREAM_DEST)"
	@echo "Done. Remember to 'sudo systemctl reload nginx'."

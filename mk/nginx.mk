# nginx.mk

NGINXDIR   ?= /etc/nginx
NGINX_MAIN ?= $(NGINXDIR)/nginx.conf
STREAMD    ?= $(NGINXDIR)/stream.conf.d

# Files in this repo
CONF_JSON_SRC    ?= conf/json_stream.conf
CONF_UDP_SRC     ?= conf/nginx-roughtime.conf

# Destination paths
CONF_JSON_DEST   ?= $(STREAMD)/00-json_stream_log.conf
CONF_STREAM_DEST ?= $(STREAMD)/roughtime_serve.conf

# ==========================================================================
# setup nginx

.PHONY: nginx nginx-config nginx-check-stream-include nginx-enable nginx-test nginx-clean

nginx: nginx-config ## Install stream include prereqs, JSON log, UDP conf, enable, and test
	$(SUBMAKE) nginx-enable
	$(SUBMAKE) nginx-test

$(STREAMD):
	@echo ">> Ensuring stream directory: $(STREAMD)"
	sudo install -d -m 0755 "$@"

$(CONF_JSON_DEST): $(CONF_JSON_SRC) | $(STREAMD)
	@echo ">> Installing JSON stream log -> $(CONF_JSON_DEST)"
	sudo install -D -m 0644 "$<" "$@"

$(CONF_STREAM_DEST): $(CONF_UDP_SRC) | $(STREAMD)
	@echo ">> Installing UDP RoughTime conf -> $(CONF_STREAM_DEST)"
	sudo install -D -m 0644 "$<" "$@"

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

# nginx-check-stream-include: ## Verify nginx.conf includes stream{} or stream.conf.d/*.conf
# 	@echo ">> Verifying Nginx includes the new stream configs..."
# 	if sudo nginx -T 2>/dev/null | grep -q "$(CONF_STREAM_DEST)"; then
# 	  echo "  OK: Nginx is picking up $(CONF_STREAM_DEST)";
# 	else
# 	  echo "ERROR: Nginx is NOT including the stream configs.";
# 	  echo "Please ensure $(NGINX_MAIN) contains the following block:";
# 	  echo "";
# 	  echo "stream {";
# 	  echo "    include $(STREAMD)/*.conf;";
# 	  echo "}";
# 	  echo "";
# 	  exit 1;
# 	fi

nginx-config: $(CONF_JSON_DEST) $(CONF_STREAM_DEST) nginx-check-stream-include

nginx-enable: ## Enable and start nginx (idempotent)
	@echo ">> Enabling and starting nginx..."
	sudo systemctl enable --now nginx

nginx-test: ## Validate nginx config and reload if valid
	@echo ">> Validating and reloading Nginx..."
	sudo nginx -t
	sudo systemctl reload nginx

nginx-clean: ## Remove installed stream configs (does not edit nginx.conf)
	@echo ">> Removing stream configs..."
	sudo rm -f "$(CONF_JSON_DEST)" "$(CONF_STREAM_DEST)"
	sudo systemctl reload nginx

# systemd.mk

SERVICE_SRC  ?= conf/$(SERVICE_NAME).service
UNIT_DEST    ?= /etc/systemd/system/$(SERVICE_NAME).service

# ==========================================================================
# systemd management

.PHONY: server-install server-enable server-restart server-stop server-status server-logs server-uninstall

$(UNIT_DEST): $(SERVICE_SRC)
	@echo ">> Installing systemd unit: $< -> $@"
	test -f "$<" || { echo "ERROR: missing $<"; exit 1; }

	# analyze before install
	sudo systemd-analyze verify "$<" || { echo "ERROR: Unit verify FAILED"; exit 2; }
	sudo install -C -m 0644 "$<" "$@"

	# analyze before reload -- belt and suspenders
	@sudo systemd-analyze verify "$@"
	sudo systemctl daemon-reload

server-install: $(UNIT_DEST) ## Install systemd unit and daemon-reload

server-enable: | $(UNIT_DEST) ## Enable and start the service
	@echo ">> Enabling and starting $(SERVICE_NAME)..."
	sudo systemctl enable --now "$(SERVICE_NAME)"
	$(SUBMAKE) server-status

server-restart: | $(UNIT_DEST) ## Restart the service and show status
	@echo ">> Restarting $(SERVICE_NAME)..."
	sudo systemctl restart "$(SERVICE_NAME)"
	sudo journalctl -u "$(SERVICE_NAME)" -f

server-stop: ## Stop the service and show last 20 log lines
	@echo ">> Stopping $(SERVICE_NAME)..."
	sudo systemctl stop "$(SERVICE_NAME)"
	$(SUBMAKE) server-status

server-status: ## Show service status and recent logs
	@sudo systemctl is-active --quiet "$(SERVICE_NAME)" && echo "Status: ACTIVE" || echo "Status: INACTIVE"
	sudo systemctl status "$(SERVICE_NAME)" --no-pager || true
	echo "--- Recent Logs ---"
	sudo journalctl -u "$(SERVICE_NAME)" -n 20 --no-pager

server-logs: ## Follow logs
	sudo journalctl -u "$(SERVICE_NAME)" -f

server-uninstall: ## Stop/disable and remove the unit
	sudo systemctl disable --now "$(SERVICE_NAME)" || true
	sudo rm -f "$(UNIT_DEST)"
	sudo systemctl daemon-reload

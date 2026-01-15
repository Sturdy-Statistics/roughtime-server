# ---------- server.mk ----------
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- recursive make commands ---
SELF    := $(lastword $(MAKEFILE_LIST))
SUBMAKE := $(MAKE) --no-print-directory -f $(SELF)

SERVICE_NAME ?= roughtime
REPO_NAME    ?= roughtime-server

SERVICE_SRC  ?= conf/$(SERVICE_NAME).service
UNIT_DEST    ?= /etc/systemd/system/$(SERVICE_NAME).service

APP_USER  ?= $(SERVICE_NAME)
APP_GROUP ?= $(APP_USER)
APP_HOME  ?= /opt/$(APP_USER)
APP_DIR   ?= $(APP_HOME)/$(REPO_NAME)

LOGS_DIR  ?= $(APP_HOME)/logs/

REPO_USER   ?= ec2-user
REPO_HOME   ?= /home/$(REPO_USER)
REPO_DIR    ?= $(REPO_HOME)/$(REPO_NAME)
REPO_RUNDIR ?= $(REPO_DIR)

# --- artifact settings ---
RELEASES_DIR      ?= $(APP_DIR)/releases
STABLE_JAR_LINK   ?= $(APP_DIR)/current-standalone.jar
JAR_GLOB          ?= target/*-standalone.jar
KEEP_RELEASES     ?= 5

.PHONY: help server server-user app-dirs git-pull build-uber stage-jar \
	server-install server-enable server-restart server-stop server-status \
	server-logs server-uninstall server-verify deploy prune-releases \
	releases rollback rollback-n rollback-to

help: ## Show server service targets
	@awk 'BEGIN{FS=":.*##"; OFS=""} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Orchestrated "first time" or "full" install
server: ## Install/update unit, build jar, promote artifact, enable+start service
	$(SUBMAKE) server-user
	$(SUBMAKE) app-dirs
	$(SUBMAKE) git-pull
	$(SUBMAKE) build-uber
	$(SUBMAKE) stage-jar
	$(SUBMAKE) server-install
	$(SUBMAKE) server-enable
	$(SUBMAKE) prune-releases

server-user: ## Create a dedicated unprivileged user (idempotent)
	@echo ">> Ensuring service user $(APP_USER) exists"
	@if ! getent passwd "$(APP_USER)" >/dev/null; then
	  sudo useradd --system --home "$(APP_HOME)" --shell /usr/sbin/nologin --user-group "$(APP_USER)";
	fi

app-dirs: ## Create app home with correct ownership (idempotent)
	@echo ">> Ensuring $(APP_HOME) and $(APP_DIR) exist and are owned by $(APP_USER):$(APP_GROUP)"
	@sudo install -d -m 0700 -o $(APP_USER) -g $(APP_GROUP) "$(APP_HOME)"
	@sudo install -d -m 0700 -o $(APP_USER) -g $(APP_GROUP) "$(APP_DIR)"
	@sudo install -d -m 0700 -o $(APP_USER) -g $(APP_GROUP) "$(RELEASES_DIR)"
	@sudo install -d -m 0700 -o $(APP_USER) -g $(APP_GROUP) "$(LOGS_DIR)"

git-pull: ## Pull latest code in REPO_DIR
	@echo ">> Pulling repo in $(REPO_DIR)"
	test -d "$(REPO_DIR)/.git" || { echo "ERROR: $(REPO_DIR) is not a git repo"; exit 2; }
	git -C "$(REPO_DIR)" fetch --prune
	git -C "$(REPO_DIR)" pull --ff-only

# --- Build & stage artifact -------------------------------------------

build-uber: ## Build uberjar via tools.build (:build alias must exist)
	@echo ">> Building uberjar with tools.build"
	cd "$(REPO_RUNDIR)"
	clojure -T:build uber

stage-jar: ## Copy newest *-standalone.jar to releases/ and update stable symlink if changed
	@echo ">> Staging latest uberjar into $(RELEASES_DIR) and updating $(STABLE_JAR_LINK)"

	@sudo install -d -m 0755 -o "$(APP_USER)" -g "$(APP_GROUP)" "$(RELEASES_DIR)"

	@cd "$(REPO_RUNDIR)"
	JAR_REL="$$(ls -1t $(JAR_GLOB) 2>/dev/null | head -n1 || true)"
	@if [ -z "$$JAR_REL" ]; then
	  echo "ERROR: no uberjar found (pattern: $(REPO_RUNDIR)/$(JAR_GLOB))"
	  exit 3
	fi
	@echo ">> Found artifact (relative): $$JAR_REL"

	JAR_ABS="$(REPO_RUNDIR)/$$JAR_REL"
	BASENAME="$${JAR_REL##*/}"
	TMP_DST="$(RELEASES_DIR)/.$$BASENAME.tmp"
	FINAL_DST="$(RELEASES_DIR)/$$BASENAME"

	@sudo install -D -m 0600 "$$JAR_ABS" "$$TMP_DST"
	@sudo chown "$(APP_USER):$(APP_GROUP)" "$$TMP_DST"
	@sudo mv -f "$$TMP_DST" "$$FINAL_DST"

	resolve() { readlink -f "$$1" 2>/dev/null || realpath -m "$$1"; }
	CUR="$$( [ -L '$(STABLE_JAR_LINK)' ] && resolve '$(STABLE_JAR_LINK)' || echo '' )"
	NEW="$$(resolve "$$FINAL_DST")"

	@if [ "$$CUR" = "$$NEW" ]; then
	  echo ">> Symlink already points to latest; not restarting."
	else
	  sudo ln -sfn "$$FINAL_DST" "$(STABLE_JAR_LINK)"
	  sudo chown -h "$(APP_USER):$(APP_GROUP)" "$(STABLE_JAR_LINK)"
	  sudo touch "$(STABLE_JAR_LINK)"
	  echo ">> Updated symlink -> $$FINAL_DST"
	fi

prune-releases: ## Keep only the newest $(KEEP_RELEASES) artifacts in releases/
	@echo ">> Pruning old releases in $(RELEASES_DIR) (keeping $(KEEP_RELEASES))"
	@sudo -u "$(APP_USER)" bash -lc '\
	  set -euo pipefail; \
	  if [ ! -d "$(RELEASES_DIR)" ]; then \
	    echo ">> No releases directory yet — skipping prune."; \
	    exit 0; \
	  fi; \
	  cd "$(RELEASES_DIR)"; \
	  OLD_JARS="$$(ls -1t *-standalone.jar 2>/dev/null | tail -n +$$(( $(KEEP_RELEASES) + 1 )) || true)"; \
	  if [ -z "$$OLD_JARS" ]; then \
	    echo ">> Nothing to prune."; \
	  else \
	    echo ">> Removing:"; \
	    echo "$$OLD_JARS" | sed "s/^/   /"; \
	    echo "$$OLD_JARS" | xargs -r rm -f; \
	  fi \
	'

# --- Systemd management ------------------------------------------------------

server-install: ## Install systemd unit and daemon-reload (idempotent)
	@echo ">> Installing systemd unit: $(SERVICE_SRC) -> $(UNIT_DEST)"
	@if [ ! -f "$(SERVICE_SRC)" ]; then echo "ERROR: missing $(SERVICE_SRC). Run from repo root?"; exit 1; fi
	@sudo install -D -m 0644 "$(SERVICE_SRC)" "$(UNIT_DEST)"
	@sudo systemd-analyze verify "$(UNIT_DEST)" || { echo ">> Unit verify FAILED"; exit 2; }
	@sudo systemctl daemon-reload

server-enable: ## Enable and start the service (idempotent)
	@echo ">> Enabling and starting $(SERVICE_NAME)..."
	@sudo systemctl enable --now $(SERVICE_NAME)
	@systemctl status $(SERVICE_NAME) --no-pager || true

server-restart: ## Restart the service and show last 80 log lines
	@sudo systemctl restart $(SERVICE_NAME)
	@journalctl -u $(SERVICE_NAME) -n 80 --no-pager || true

server-stop: ## Stop the service and show last 80 log lines
	@sudo systemctl stop $(SERVICE_NAME)
	@journalctl -u $(SERVICE_NAME) -n 80 --no-pager || true

server-status: ## Show service status
	@systemctl status $(SERVICE_NAME) --no-pager || true

server-logs: ## Follow logs
	@journalctl -u $(SERVICE_NAME) -f

server-uninstall: ## Stop/disable and remove the unit
	@sudo systemctl disable --now $(SERVICE_NAME) || true
	@sudo rm -f "$(UNIT_DEST)"
	@sudo systemctl daemon-reload

server-verify: ## Quick UDP sanity checks (port/listener/logs)
	@echo ">> UDP sockets on 2002"; sudo ss -lunp | grep 2002 || true
	@echo ">> Last 20 lines of logs"; journalctl -u $(SERVICE_NAME) -n 20 --no-pager || true

deploy: ## Pull latest, build uberjar, promote artifact, restart, tail logs
	@$(SUBMAKE) git-pull
	@$(SUBMAKE) build-uber
	@$(SUBMAKE) stage-jar
	@$(SUBMAKE) server-restart
	@$(SUBMAKE) server-logs


# --- Rollback ------------------------------------------------------

releases: ## List available artifacts (newest first) with index
	@echo ">> Releases in $(RELEASES_DIR) (newest first)"
	@sudo -u "$(APP_USER)" bash -lc '\
	  set -euo pipefail; \
	  if [ ! -d "$(RELEASES_DIR)" ]; then \
	    echo "No releases dir: $(RELEASES_DIR)"; \
	    exit 0; \
	  fi; \
	  cd "$(RELEASES_DIR)"; \
	  resolve() { readlink -f "$$1" 2>/dev/null || realpath -m "$$1"; }; \
	  CUR="$$( [ -L "$(STABLE_JAR_LINK)" ] && resolve "$(STABLE_JAR_LINK)" || echo "" )"; \
	  mapfile -t FILES < <(ls -1t *-standalone.jar 2>/dev/null || true); \
	  if [ $${#FILES[@]} -eq 0 ]; then \
	    echo "No artifacts found."; \
	    exit 0; \
	  fi; \
	  i=1; \
	  for f in "$${FILES[@]}"; do \
	    tag=""; \
	    if [ -n "$$CUR" ] && [ "$$CUR" = "$$(resolve "$$f")" ]; then \
	      tag=" <== current"; \
	    fi; \
	    printf "%2d) %s%s\n" "$$i" "$$f" "$$tag"; \
	    i=$$((i+1)); \
	  done \
	'

rollback-to: ## Roll back symlink to a specific artifact: make rollback-to NAME=<filename-in-releases>
	@if [ -z "$(NAME)" ]; then \
	  echo "Usage: make rollback-to NAME=<filename-in-releases>"; exit 2; \
	fi
	@sudo -u "$(APP_USER)" bash -lc '\
	  set -euo pipefail; \
	  if [ ! -d "$(RELEASES_DIR)" ]; then \
	    echo "No releases dir: $(RELEASES_DIR)"; exit 3; \
	  fi; \
	  cd "$(RELEASES_DIR)"; \
	  if [ ! -f "$(NAME)" ]; then \
	    echo "Artifact not found: $(RELEASES_DIR)/$(NAME)"; exit 4; \
	  fi; \
	  echo ">> Rolling back to: $(NAME)"; \
	  resolve() { readlink -f "$$1" 2>/dev/null || realpath -m "$$1"; }; \
	  TARGET_ABS="$$(resolve "$(NAME)")"; \
	  ln -sfn "$$TARGET_ABS" "$(STABLE_JAR_LINK)"; \
	  touch "$(STABLE_JAR_LINK)"; \
	  echo ">> Symlink -> $$TARGET_ABS" \
	'
	@$(SUBMAKE) server-restart || true
	@$(SUBMAKE) releases

rollback-n: ## Roll back symlink to the N-th newest artifact: make rollback-n N=3
	@if [ -z "$(N)" ]; then \
	  echo "Usage: make rollback-n N=<number>"; exit 2; \
	fi
	@echo ">> Rolling back to N-th newest (N=${N}) in $(RELEASES_DIR)"
	TARGET="$$(sudo -u "$(APP_USER)" bash -lc '\
	  set -euo pipefail; \
	  N="${N}"; \
	  if [ ! -d "$(RELEASES_DIR)" ]; then \
	    echo "No releases dir: $(RELEASES_DIR)"; exit 3; \
	  fi; \
	  cd "$(RELEASES_DIR)"; \
	  LIST=$$(ls -1t *-standalone.jar 2>/dev/null || true); \
	  if [ -z "$$LIST" ]; then \
	    echo "No artifacts found in $(RELEASES_DIR)"; exit 4; \
	  fi; \
	  TARGET=$$(echo "$$LIST" | sed -n "$${N}p"); \
	  if [ -z "$$TARGET" ]; then \
	    echo "No N=$$N artifact available (only $$(echo "$$LIST" | wc -l) found)"; exit 5; \
	  fi; \
	  printf "%s" "$$TARGET" \
	')"; \
	$(SUBMAKE) rollback-to NAME="$$TARGET"

rollback: ## Roll back symlink to the previous artifact (2nd newest) and restart
	@$(SUBMAKE) rollback-n N=2

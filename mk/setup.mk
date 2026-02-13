# setup.mk

LOGS_DIR      := $(APP_HOME)/logs
ARTIFACTS_DIR := $(APP_HOME)/artifacts

APPHOME_STAMP   := $(STAMP_DIR)/app-home.stamp
LOGS_STAMP      := $(STAMP_DIR)/logs.stamp
ARTIFACTS_STAMP := $(STAMP_DIR)/artifacts.stamp
RELEASES_STAMP  := $(STAMP_DIR)/releases.stamp

# ==========================================================================
# set up server for the app

system-setup: server-user $(APPHOME_STAMP) $(ARTIFACTS_STAMP) $(LOGS_STAMP) $(RELEASES_STAMP) ## Create a dedicated unprivileged user (idempotent)

server-user: ## Create a dedicated unprivileged user (idempotent)
	@if ! getent passwd "$(APP_USER)" >/dev/null; then
	  echo ">> Ensuring service user $(APP_USER) exists"
	  sudo useradd --system \
	    --home "$(APP_HOME)" \
	    --shell /usr/sbin/nologin \
	    --user-group \
	    "$(APP_USER)"
	fi

$(STAMP_DIR): | server-user
	@install -d -m 0700 "$@"

$(APPHOME_STAMP): | $(STAMP_DIR)
	@sudo install -d -m 0700 -o "$(APP_USER)" -g "$(APP_GROUP)" "$(APP_HOME)"
	touch "$@"

$(ARTIFACTS_STAMP): | $(STAMP_DIR)
	@sudo install -d -m 0700 -o "$(APP_USER)" -g "$(APP_GROUP)" "$(ARTIFACTS_DIR)"
	touch "$@"

$(LOGS_STAMP): | $(STAMP_DIR)
	@sudo install -d -m 0700 -o "$(APP_USER)" -g "$(APP_GROUP)" "$(LOGS_DIR)"
	touch "$@"

$(RELEASES_STAMP): | $(STAMP_DIR)
	@sudo install -d -m 0700 -o "$(APP_USER)" -g "$(APP_GROUP)" "$(RELEASES_DIR)"
	touch $@

.PHONY: teardown-user teardown-app-home
teardown-user:
	@echo ">> Removing user $(APP_USER)..."
	# Only remove if exists
	if getent passwd "$(APP_USER)" >/dev/null; then \
		sudo userdel "$(APP_USER)"; \
	else \
		echo "User $(APP_USER) not found."; \
	fi
	# Group usually deleted with user, but ensure it's gone
	if getent group "$(APP_GROUP)" >/dev/null; then \
		sudo groupdel "$(APP_GROUP)" || true; \
	fi

teardown-app-home:
	@echo "   Removing $(APP_HOME)"
	test -n "$(APP_HOME)" && test "$(APP_HOME)" != "/" && test "$(APP_HOME)" != "/opt" \
	  || { echo "ERROR: APP_HOME unsafe: $(APP_HOME)"; exit 3; }
	sudo rm -rf -- "$(APP_HOME)"
	sudo rm -rf -- "$(STAMP_DIR)"

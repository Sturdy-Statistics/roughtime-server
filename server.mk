# ==========================================================================
# server.mk v0.1.0
#
# Makefile for managing the server
#
# Server is assumed to run in systemd service defined in conf/$(SERVICE_NAME).service
#
# --------------------------------------------------------------------------


# ==========================================================================
# frontmatter

.ONESHELL:
.DELETE_ON_ERROR:
.SHELLFLAGS := -euo pipefail -c
SHELL := /bin/bash
.DEFAULT_GOAL := help

# name of the makefile
# MUST BE before any includes!
SELF := $(lastword $(MAKEFILE_LIST))

# ==========================================================================
# show help message

.PHONY: help
help: ## Show server service targets
	@awk 'BEGIN{FS=":.*##"; OFS=""} /^[a-zA-Z0-9_.\/-]+:.*##/ {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ==========================================================================
# installation

.PHONY: server deploy

server: install-jar server-enable server-logs ## Orchestrated first-time/full install

deploy: install-jar server-restart server-logs ## Pull latest, restart, tail logs

# ==========================================================================
# variable definitions

include defs.mk

# ==========================================================================
# sudo helpers

SUDO_APP := sudo -u "$(APP_USER)"

# prevent accidental nesting (Note = not :=)
ifndef IN_SUDO_AS_APP
  SUBMAKE_AS_APP = $(SUDO_APP) IN_SUDO_AS_APP=1 $(SUBMAKE)
else
  SUBMAKE_AS_APP = $(SUBMAKE)
endif

# ==========================================================================
# components

include mk/deploy.mk
include mk/systemd.mk

# ==========================================================================
# recursive make command

SUBMAKE := $(MAKE) --no-print-directory -f $(SELF) $(SUBMAKE_VARS)

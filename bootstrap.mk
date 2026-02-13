# ==========================================================================
# bootstrap.mk v0.1.0
#
# Makefile for setting up the server
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

.PHONY: setup

setup: prereq system-setup

# ==========================================================================
# variable definitions

include defs.mk

# ==========================================================================
# components

include mk/prereq.mk
include mk/setup.mk
include mk/nginx.mk
include mk/secrets.mk

# ==========================================================================
# recursive make command

SUBMAKE := $(MAKE) --no-print-directory -f $(SELF) $(SUBMAKE_VARS)

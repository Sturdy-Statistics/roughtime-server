# --- global settings ---
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- recursive make commands ---
SELF := $(lastword $(MAKEFILE_LIST))
SUBMAKE := $(MAKE) --no-print-directory -f $(SELF)

# Config
APP_USER ?= ec2-user
APP_HOME ?= /home/$(APP_USER)
REPO_URL ?= https://github.com/Sturdy-Statistics/roughtime-server.git

REPO_DIR := $(APP_HOME)/roughtime-server
REPO_HEAD := $(REPO_DIR)/.git/HEAD

# Tools
DNF := sudo dnf -y

.PHONY: help prereq versions bootstrap clean distclean test

help: ## Show server service targets
	@awk 'BEGIN{FS=":.*##"; OFS=""} /^[a-zA-Z0-9_.\/-]+:.*##/ {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: $(REPO_HEAD) ## Prepare a runnable server: install deps and clone repo

prereq: ## Install build tools, JDK, clojure, nginx
	@echo ">> Installing system packages..."
	$(DNF) groupinstall "Development Tools"
	$(DNF) install java-17-amazon-corretto-devel nginx nginx-mod-stream

	if ! command -v clojure >/dev/null 2>&1; then
	    echo ">> Installing Clojure CLI..."
	    curl -L -O https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh
	    chmod +x linux-install.sh
	    sudo ./linux-install.sh
	    rm -f linux-install.sh
	fi
	$(SUBMAKE) versions

versions: ## Show tool versions
	@echo "== Versions =="
	echo -n "java:     " && (which java && java -version | head -n1) || echo "missing"
	echo -n "clojure:  " && (which clojure && clojure --version) || echo "missing"
	echo -n "nginx:    " && (nginx -v 2>&1 | head -n1) || echo "missing"

test: ## Run the Clojure test suite
	cd $(REPO_DIR) && clojure -X:test

clean: ## Remove build artifacts in the repo
	@echo ">> Cleaning build artifacts..."
	if [ -d "$(REPO_DIR)" ]; then
	    cd $(REPO_DIR) && rm -rf target/ .cpcache/
	fi

distclean: clean ## COMPLETELY remove the repository directory
	@echo ">> Removing repository directory..."
	rm -rf $(REPO_DIR)

# ===== Actual file-building rules =====

$(REPO_HEAD): | prereq
	@echo ">> Cloning or updating repository at $(REPO_DIR) ..."
	if [ ! -d $(REPO_DIR)/.git ]; then
	    sudo -u $(APP_USER) git clone $(REPO_URL) $(REPO_DIR)
	else
	    echo "Repo exists; pulling latest..."
	    sudo -u $(APP_USER) git -C $(REPO_DIR) pull --ff-only
	fi
	test -f $(REPO_HEAD)

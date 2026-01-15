# -------- Config --------
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

SHELL := /bin/bash
.DEFAULT_GOAL := help

SECRETS_DIR ?= roughtime-secrets
DEST_DIR    ?= /etc/roughtime
PCRS        ?= 0+2

FILES := password.edn keychain.b64 longterm.prv.b64 longterm.pub

ENCRYPT_CMD := systemd-creds encrypt --tpm2-pcrs="$(PCRS)"

# -----------------------------------------------------------------------------
# Help
.PHONY: help
help: ## Show this help (target list)
	@printf "\n\033[1mRoughtime secrets targets\033[0m\n"
	@awk 'BEGIN{FS=":.*##"; OFS=""} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# -------- Phony targets --------
.PHONY: all provision make-secrets encrypt message clean check-tools verify

all: provision

provision: check-tools make-secrets encrypt message ## End-to-end: generate, stage, encrypt, secure, remind.

make-secrets: ## Generate plaintext secrets into SECRETS_DIR
	@echo ">> Generating secrets into '$(SECRETS_DIR)'"
	clojure -X:make-secrets :secrets-dir '"$(SECRETS_DIR)"'
	for f in $(FILES); do
	  if [ -f "$(SECRETS_DIR)/$$f" ]; then chmod 0600 "$(SECRETS_DIR)/$$f"; fi
	done

encrypt: ## Encrypt each plaintext file to .cred with TPM2 sealing and tight perms
	@sudo install -d -m 0700 -o root -g root "$(DEST_DIR)"
	for f in $(FILES); do
	  name="$$f"
	  [ -f "$(SECRETS_DIR)/$$f" ] || { echo "ERROR: missing $(SECRETS_DIR)/$$f"; exit 2; }
	  echo "==> Encrypting $(SECRETS_DIR)/$$f -> $(DEST_DIR)/$$f.cred (PCRS=$(PCRS))"
	  sudo $(ENCRYPT_CMD) --name "$$name" \
	       "$(SECRETS_DIR)/$$f" "$(DEST_DIR)/$$f.cred"
	  sudo chown root:root "$(DEST_DIR)/$$f.cred"
	  sudo chmod 0400      "$(DEST_DIR)/$$f.cred"
	done

message: ## Reminder to back up the plaintext directory
	@echo
	@echo "✔ TPM-sealed credentials written to: $(DEST_DIR)"
	@echo "⚠ Plaintext secrets are at: $(SECRETS_DIR)"
	@echo "  Back them up securely, then run: make clean to securely delete"
	@echo

clean: ## Securely destroy plaintext copies in SECRETS_DIR
	@echo ">> Shredding plaintext workdir: $(SECRETS_DIR)"
	@for f in $(FILES); do
	  if [ -f "$(SECRETS_DIR)/$$f" ]; then
	    echo "   shredding $(SECRETS_DIR)/$$f"
	    shred -u "$(SECRETS_DIR)/$$f"
	  fi
	done
	@rmdir "$(SECRETS_DIR)" 2>/dev/null || true
	@echo "Workdir plaintext removed (if present)."

check-tools: ## Basic tool checks
	@command -v clojure >/dev/null || { echo "missing: clojure"; exit 1; }
	@command -v systemd-creds >/dev/null || { echo "missing: systemd-creds"; exit 1; }

verify: ## Try decrypting .cred files to /dev/null (sanity check)
	@for f in $(FILES); do
	  echo ">> Verifying $(DEST_DIR)/$$f.cred (internal name: $$f)";
	  sudo systemd-creds decrypt --name "$$f" "$(DEST_DIR)/$$f.cred" - >/dev/null;
	done

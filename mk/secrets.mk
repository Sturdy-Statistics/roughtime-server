# secrets.mk

SECRETS_DIR ?= /dev/shm/$(SERVICE_NAME)-secrets
DEST_DIR    ?= /etc/roughtime
PCRS        ?= 0+2

PASSWORD_NAME := password.bytes
PASSWORD      := $(SECRETS_DIR)/$(PASSWORD_NAME)

INSTALLED_PASSWORD := $(DEST_DIR)/$(PASSWORD_NAME).cred
# Shadow stamp file for dependency tracking on root-owned files
INSTALLED_STAMP    := .installed/$(SERVICE_NAME)/$(PASSWORD_NAME).cred.stamp

# Quotes handled in variable definition to prevent double-quoting issues later
BACKUP_PUB := resources/tempel_server_keys/backup_pub.key
BACKUP_PRV := $(SECRETS_DIR)/OFFLINE_backup_keychain.enc

ENCRYPT_CMD := systemd-creds encrypt --tpm2-pcrs="$(PCRS)"

# ==========================================================================
# secrets

.PHONY: secrets clean-secrets verify-secrets
secrets: check-tools | $(INSTALLED_STAMP) $(BACKUP_PRV) ## End-to-end: generate, stage, encrypt, secure, remind.

$(SECRETS_DIR):
	@echo ">> Creating plaintext workdir: $(SECRETS_DIR)"
	install -d -m 0700 "$(SECRETS_DIR)"

# Generate plaintext password into $(SECRETS_DIR)
$(PASSWORD): | $(SECRETS_DIR)
	@echo ">> Generating 32-byte password into: $@"
	umask 077
	head -c 32 /dev/urandom > "$@"
	chmod 0600 "$@"

# Encrypt password with TPM2 sealing and tight perms
$(INSTALLED_STAMP): $(PASSWORD)
	@command -v systemd-creds >/dev/null || { echo "missing: systemd-creds"; exit 1; }
	[ -f "$(PASSWORD)" ] || { echo "ERROR: missing $(PASSWORD)"; exit 2; }

	if sudo test -e "$(INSTALLED_PASSWORD)" && [ "$(FORCE)" != "1" ]; then
	  echo "ERROR: Refusing to overwrite installed credential: $(INSTALLED_PASSWORD)"
	  echo "Rotating this secret will likely cause data loss."
	  echo "If you truly intend to rotate, run:"
	  echo "  make FORCE=1 overwrite-secrets"
	  exit 11;
	fi

	sudo install -d -m 0700 -o root -g root "$(DEST_DIR)"
	echo "==> Encrypting $(PASSWORD) -> $(INSTALLED_PASSWORD) (PCRS=$(PCRS))"

	sudo $(ENCRYPT_CMD) --name "$(PASSWORD_NAME)" \
	  "$(PASSWORD)" "$(INSTALLED_PASSWORD)"
	sudo chown root:root "$(INSTALLED_PASSWORD)"
	sudo chmod 0400      "$(INSTALLED_PASSWORD)"

	mkdir -p "$$(dirname "$@")"
	touch "$@"

	echo
	echo "✔ TPM-sealed credential written to: $(INSTALLED_PASSWORD)"
	echo "⚠ Plaintext secret is at: $(PASSWORD)"
	echo "  Back it up securely, then run: make clean-secrets"
	echo
	echo "Password in base64 is:"
	cat $(PASSWORD) | base64
	echo
	echo "Unit line:"
	echo "  LoadCredentialEncrypted=$(PASSWORD_NAME):$(INSTALLED_PASSWORD)"
	echo

.PHONY: overwrite-secrets
overwrite-secrets: $(INSTALLED_STAMP)

$(BACKUP_PRV): | $(SECRETS_DIR)
	@echo ">> Generating backup keys into '$(SECRETS_DIR)'"
	# Ensure quotes are passed correctly to clojure
	clojure -X:make-backup-key :secrets-dir '"$(SECRETS_DIR)"'
	echo
	echo "⚠ Backup private key is at: $(BACKUP_PRV)"
	echo "  It is encrypted using the password you entered at the CLI prompt."
	echo "  It can be used to recover data if your TPM-sealed secret is lost."
	echo "  Back it up securely, then run: make clean-secrets"
	echo


clean-secrets: ## Remove plaintext copies in SECRETS_DIR (tmpfs; best-effort shred if available)
	@echo ">> Removing plaintext workdir: $(SECRETS_DIR)"
	if [ -d "$(SECRETS_DIR)" ]; then
	  if command -v shred >/dev/null; then
	    find "$(SECRETS_DIR)" -type f -print0 | xargs -0 -r shred -uf
	  else
	    find "$(SECRETS_DIR)" -type f -print0 | xargs -0 -r rm -f
	  fi;
	  rmdir "$(SECRETS_DIR)" 2>/dev/null || true
	  rm -rf "$(dir $(INSTALLED_STAMP))"
	fi
	echo "Plaintext workdir removed (if present)."

verify-secrets: ## Sanity check: decrypt installed password cred to /dev/null
	@command -v systemd-creds >/dev/null || { echo "missing: systemd-creds"; exit 1; }
	echo ">> Verifying installed credential: $(INSTALLED_PASSWORD)"
	sudo test -f "$(INSTALLED_PASSWORD)" || { echo "ERROR: missing $(INSTALLED_PASSWORD)"; exit 3; }
	sudo systemd-creds decrypt --name "$(PASSWORD_NAME)" "$(INSTALLED_PASSWORD)" - >/dev/null
	echo "✔ Verify OK"

.PHONY: teardown-secrets
teardown-secrets:
	# Ensures DEST_DIR is not empty, not root, and contains the expected service name or path structure.
	@if [ -z "$(DEST_DIR)" ] || [ "$(DEST_DIR)" = "/" ] || [ "$(DEST_DIR)" = "/etc" ]; then \
		echo "ERROR: DEST_DIR ($(DEST_DIR)) looks unsafe to delete."; exit 9; \
	fi
	@echo "WARNING: Deleting $(DEST_DIR)..."
	sudo rm -fr -- "$(DEST_DIR)"
	rm -f "$(INSTALLED_STAMP)"

check-tools: ## Basic tool checks
	@command -v clojure >/dev/null || { echo "missing: clojure"; exit 1; }
	@command -v systemd-creds >/dev/null || { echo "missing: systemd-creds"; exit 1; }

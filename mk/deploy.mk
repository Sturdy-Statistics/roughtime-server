# deploy.mk

JAR_GLOB      := *-standalone.jar
KEEP_RELEASES := 5

TARGET_DIR      := target
INSTALLED_STAMP := .installed/$(SERVICE_NAME)/uberjar.stamp

# ==========================================================================
# build and stage artifact

.PHONY: install-jar
install-jar: build-uber stage-jar prune-releases

# ==========================================================================
# build and stage artifact

.PHONY: build-uber stage-jar stage-jar-as-user

git-pull: ## Pull latest code
	@echo ">> Pulling repo"
	test -d ".git" || { echo "ERROR: not a git repo"; exit 2; }
	git fetch --prune
	git pull --ff-only

build-uber: git-pull ## Build uberjar via tools.build
	@echo ">> Building uberjar with tools.build"
	clojure -T:build uber
	mkdir -p "$$(dirname "$(INSTALLED_STAMP)")"
	touch $(INSTALLED_STAMP)

stage-jar: $(INSTALLED_STAMP) ## Copy newest *-standalone.jar (+ signature) to releases/ and update stable symlink if change
	@echo ">> Staging latest uberjar into $(RELEASES_DIR) and updating $(STABLE_JAR_LINK)"

	JAR_FILE="$$(ls -1t $(TARGET_DIR)/$(JAR_GLOB) 2>/dev/null | head -n1 || true)"
	if [ -z "$$JAR_FILE" ]; then
	  echo "ERROR: no uberjar found (pattern: $(TARGET_DIR)/$(JAR_GLOB))"
	  exit 3
	fi

	BASENAME="$${JAR_FILE##*/}"
	JAR_DEST="$(RELEASES_DIR)/$$BASENAME"

	sudo install -C -m 0600 -o "$(APP_USER)" -g "$(APP_GROUP)" "$$JAR_FILE" "$$JAR_DEST"

	$(SUBMAKE_AS_APP) stage-jar-as-user JAR_DEST="$$JAR_DEST"

.PHONY: stage-jar-as-user
stage-jar-as-user:
	@echo ">> Updating stable symlinks"
	CUR=$$(readlink "$(abspath $(STABLE_JAR_LINK))" 2>/dev/null || echo "")

	if [ "$$CUR" = "$(abspath $(JAR_DEST))" ]; then
	  echo "-- Symlink already points to latest."
	else
	  ln -sfnv "$(abspath $(JAR_DEST))" "$(abspath $(STABLE_JAR_LINK))"

	  echo "-- Updated symlink $(STABLE_JAR_LINK) -> $(JAR_DEST)"
	fi

# ==========================================================================
# prune releases

prune-releases: ## Keep only the newest $(KEEP_RELEASES) artifacts in releases/
	@$(SUBMAKE_AS_APP) prune-releases-as-user

prune-releases-as-user:
	@echo ">> Pruning old releases in $(RELEASES_DIR) (keeping $(KEEP_RELEASES))"

	CUR=$$(readlink "$(abspath $(STABLE_JAR_LINK))" 2>/dev/null || echo "")

	cd "$(RELEASES_DIR)"
	mapfile -t old < <(ls -1t -- $(JAR_GLOB) 2>/dev/null | tail -n +"$$(($(KEEP_RELEASES)+1))" || true)
	if (( $${#old[@]} == 0 )); then
	  echo "-- Nothing to prune."
	else
	  echo "-- Removing:"
	  for f in "$${old[@]}"; do
	    abs="$$(readlink -f "$$f" 2>/dev/null || echo "")"
	    if [ -n "$$CUR" ] && [ "$$abs" = "$$CUR" ]; then
	      echo "   $$f (skipping: current)"
	      continue
	    fi
	    echo "   $$f"
	    rm -f -- "$$f"
	  done
	fi

# ==========================================================================
# rollbacks

.PHONY: releases releases-as-user rollback rollback-n rollback-n-as-user

releases: ## List available artifacts (newest first) with index
	@$(SUBMAKE_AS_APP) releases-as-user

releases-as-user:
	@echo ">> Releases in $(RELEASES_DIR) (newest first)"
	cd "$(RELEASES_DIR)"

	CUR_TARGET=$$(readlink "$(abspath $(STABLE_JAR_LINK))" 2>/dev/null || echo "")

	mapfile -t FILES < <(ls -1t -- $(JAR_GLOB) 2>/dev/null || true)
	if (( $${#FILES[@]} == 0 )); then
	  echo "No artifacts found."
	  exit 0
	fi

	i=1
	for f in "$${FILES[@]}"; do
	  ABS_F=$$(readlink -f "$$f")
	  tag=""
	  if [ -n "$$CUR_TARGET" ] && [ "$$CUR_TARGET" = "$$ABS_F" ]; then
	    tag=" <== current"
	  fi
	  printf "%2d) %s%s\n" "$$i" "$$f" "$$tag"
	  i=$$((i+1))
	done

rollback: ## Roll back symlink to the previous artifact (2nd newest) and restart
	@$(SUBMAKE) rollback-n N=2

rollback-n: ## Roll back symlink to the N-th newest artifact: make rollback-n N=3
	@if [ -z "$(N)" ]; then
	  echo "Usage: make rollback-n N=<number>"
	  exit 2
	fi
	$(SUBMAKE_AS_APP) rollback-n-as-user N="$(N)"

	sudo systemctl restart "$(SERVICE_NAME)"

rollback-n-as-user:
	@echo ">> Rolling back to N-th newest (N=$$N) in $(RELEASES_DIR)"
	: "$${N:?N must be set (e.g. N=2)}"

	cd "$(RELEASES_DIR)"

	mapfile -t FILES < <(ls -1t -- $(JAR_GLOB) 2>/dev/null || true)
	if (( $${#FILES[@]} == 0 )); then
	  echo "ERROR: No artifacts found in $(RELEASES_DIR)"
	  exit 4
	fi

	idx=$$((N - 1)) # N is 1-based for humans; arrays are 0-based
	if (( idx < 0 || idx >= $${#FILES[@]} )); then
	  echo "ERROR: No N=$$N artifact available (only $${#FILES[@]} found)"
	  exit 5
	fi

	TARGET_NAME="$${FILES[$$idx]}"
	ABS_TARGET="$$(readlink -f "$$TARGET_NAME")"

	echo ">> Switching $(STABLE_JAR_LINK) -> $$TARGET_NAME"
	ln -sfnv "$$ABS_TARGET"     "$(abspath $(STABLE_JAR_LINK))"

# prereq.mk

# Tools
DNF := dnf -y

# ==========================================================================
# install prerequisites

.PHONY: prereq versions

prereq: ## Install build tools, JDK, clojure, nginx
	@echo ">> Installing system packages..."
	sudo $(DNF) install java-25-amazon-corretto-headless nginx nginx-mod-stream

	if ! command -v clojure >/dev/null 2>&1; then
	    echo ">> Installing Clojure CLI..."
	    curl -L -O https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh
	    chmod +x linux-install.sh
	    sudo ./linux-install.sh
	    rm -f linux-install.sh
	fi

versions: ## Show tool versions
	@echo "== Versions =="
	echo -n "java:     " && (which java && java -version | head -n1) || echo "missing"
	echo -n "clojure:  " && (which clojure && clojure --version) || echo "missing"
	echo -n "nginx:    " && (nginx -v 2>&1 | head -n1) || echo "missing"

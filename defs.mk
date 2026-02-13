# defs.mk

SERVICE_NAME  ?= roughtime
REPO_NAME     ?= roughtime-server

APP_USER      ?= $(SERVICE_NAME)
APP_GROUP     ?= $(APP_USER)
APP_HOME      := /opt/$(APP_USER)
RELEASES_DIR  := $(APP_HOME)/releases

STABLE_JAR_LINK := $(APP_HOME)/current-standalone.jar

STAMP_DIR    := .stamps

# Variables that must be forwarded to sub-make explicitly
UBMAKE_VARS = ""

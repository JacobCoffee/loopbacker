APP_BUNDLE := Loopbacker.app
BUILD_DIR := build
APP_CONTENTS := $(BUILD_DIR)/$(APP_BUNDLE)/Contents
SWIFT_BIN := App/Loopbacker/.build/release/Loopbacker

.DEFAULT_GOAL := help

.PHONY: help all driver app bundle clean install install-app install-driver uninstall uninstall-app uninstall-driver run

help: ## Show this help
	@echo "Loopbacker - Virtual audio loopback for macOS"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# --- Build targets ---

all: driver bundle ## Build driver + app bundle

driver: ## Build the CoreAudio virtual audio driver
	cd Driver && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build

app: ## Build the SwiftUI app binary
	cd App/Loopbacker && swift build -c release

bundle: app driver ## Package as Loopbacker.app with embedded driver
	@echo "==> Packaging Loopbacker.app..."
	mkdir -p $(APP_CONTENTS)/MacOS
	mkdir -p $(APP_CONTENTS)/Resources
	cp $(SWIFT_BIN) $(APP_CONTENTS)/MacOS/Loopbacker
	cp App/Loopbacker/Resources/Info.plist $(APP_CONTENTS)/Info.plist
	cp -R Driver/build/Loopbacker.driver $(APP_CONTENTS)/Resources/
	codesign --force --deep --sign "Apple Development: Jacob Coffee (NBMD22TJZJ)" --identifier com.jacobcoffee.loopbacker $(BUILD_DIR)/$(APP_BUNDLE)
	@echo "==> $(BUILD_DIR)/$(APP_BUNDLE) ready."

# --- Install targets ---

install: install-driver install-app ## Install driver + app to /Applications

install-driver: driver ## Install audio driver (needs sudo)
	sudo cp -R Driver/build/Loopbacker.driver /Library/Audio/Plug-Ins/HAL/
	sudo killall -9 coreaudiod || true
	@echo "==> Driver installed. Virtual device should appear in Sound settings."

install-app: bundle ## Copy Loopbacker.app to /Applications
	cp -R $(BUILD_DIR)/$(APP_BUNDLE) /Applications/
	@echo "==> Loopbacker.app installed to /Applications."

# --- Uninstall targets ---

uninstall: uninstall-driver uninstall-app ## Remove driver + app

uninstall-driver: ## Remove audio driver (needs sudo)
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/Loopbacker.driver
	sudo killall -9 coreaudiod || true
	@echo "==> Driver uninstalled."

uninstall-app: ## Remove app from /Applications
	rm -rf /Applications/Loopbacker.app
	@echo "==> App removed from /Applications."

# --- Dev ---

run: bundle ## Build and open the app
	@-killall Loopbacker 2>/dev/null; sleep 0.5
	open $(BUILD_DIR)/$(APP_BUNDLE)

clean: ## Remove all build artifacts
	rm -rf $(BUILD_DIR)
	rm -rf Driver/build
	cd App/Loopbacker && swift package clean

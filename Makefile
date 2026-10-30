APP_BUNDLE := Loopbacker.app
BUILD_DIR := build
APP_CONTENTS := $(BUILD_DIR)/$(APP_BUNDLE)/Contents
SWIFT_BIN := App/Loopbacker/.build/release/Loopbacker
# First Apple Development identity in the keychain, or ad-hoc ("-") without one. A real
# identity keeps the designated requirement stable across rebuilds, so privacy grants such
# as Screen & System Audio Recording survive reinstalls. Override: make SIGN_IDENTITY="…"
SIGN_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}'),-)

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
	mkdir -p $(APP_CONTENTS)/Frameworks
	cp $(SWIFT_BIN) $(APP_CONTENTS)/MacOS/Loopbacker
	cp App/Loopbacker/Resources/Info.plist $(APP_CONTENTS)/Info.plist
	cp App/Loopbacker/Resources/AppIcon.icns $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/logo.png $(APP_CONTENTS)/Resources/
	rm -rf $(APP_CONTENTS)/Resources/DPDFNet2_48k.mlmodelc
	cp -R App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc $(APP_CONTENTS)/Resources/
	rm -rf $(APP_CONTENTS)/Resources/FastEnhancer_M_48k.mlmodelc
	cp -R App/Loopbacker/Resources/FastEnhancer_M_48k.mlmodelc $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/DPDFNet-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/RNNoise-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/FastEnhancer-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/Airwindows-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/YSFX-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/Resources/WDL-LICENSE.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/CWebRTCAEC/LICENSE-webrtc-audio-processing.txt $(APP_CONTENTS)/Resources/
	cp App/Loopbacker/CWebRTCAEC/LICENSE-abseil.txt $(APP_CONTENTS)/Resources/
	xcrun actool App/Loopbacker/Resources/Assets.xcassets --compile $(APP_CONTENTS)/Resources \
		--platform macosx --minimum-deployment-target 26.0 --accent-color AccentColor \
		--output-partial-info-plist $(BUILD_DIR)/assets-partial.plist >/dev/null
	cp -R Driver/build/Loopbacker.driver $(APP_CONTENTS)/Resources/
	rm -rf $(APP_CONTENTS)/Frameworks/Sparkle.framework
	cp -R App/Loopbacker/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
		$(APP_CONTENTS)/Frameworks/
	scripts/sign-sparkle.sh $(BUILD_DIR)/$(APP_BUNDLE) "$(SIGN_IDENTITY)"
	codesign --force --deep --options runtime --entitlements App/Loopbacker/Resources/Loopbacker.entitlements \
		--sign "$(SIGN_IDENTITY)" --identifier com.jacobcoffee.loopbacker $(BUILD_DIR)/$(APP_BUNDLE)
	codesign --verify --deep --strict $(BUILD_DIR)/$(APP_BUNDLE)
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

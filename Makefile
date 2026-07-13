PROJECT   := ChatterboxiOS/ChatterboxiOS.xcodeproj
SCHEME    := ChatterboxiOS
CONFIG    ?= Debug
# Override SIMULATOR to target a specific device, e.g.:
#   make run SIMULATOR="iPhone 17 Pro"
SIMULATOR ?= iPhone 17 Pro
# Look up the UDID from xcodebuild's available destinations (Xcode 26 iOS 26.2)
SIM_UDID   = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
               -showdestinations 2>/dev/null | \
               grep "name:$(SIMULATOR) }" | head -1 | \
               sed 's/.*id:\([A-Z0-9-]*\).*/\1/')
DEST       = platform=iOS Simulator,id=$(SIM_UDID)

# ── Bootstrap (build Rust library) ──────────────────────────────────────────

.PHONY: bootstrap bootstrap-release
bootstrap:
	./bootstrap.sh

bootstrap-release:
	./bootstrap.sh --release

# ── Xcode build ─────────────────────────────────────────────────────────────

.PHONY: build
build:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME) \
	  -configuration $(CONFIG) \
	  -destination "$(DEST)" \
	  build 2>&1 | xcbeautify --quiet 2>/dev/null || \
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME) \
	  -configuration $(CONFIG) \
	  -destination "$(DEST)" \
	  build

# ── Run in simulator ─────────────────────────────────────────────────────────
# Builds, then boots the target simulator and launches the app.

DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: run
run: build
	@SIM_ID="$(SIM_UDID)"; \
	 [ -z "$$SIM_ID" ] && echo "Simulator '$(SIMULATOR)' not found. Run: make simulators" && exit 1; \
	 echo "Booting $$SIM_ID…"; \
	 xcrun simctl boot "$$SIM_ID" 2>/dev/null || true; \
	 open -a Simulator; \
	 APP=$$(find "$(DERIVED_DATA)" -name "ChatterboxiOS.app" \
	          -path "*/Build/Products/Debug-iphonesimulator/*" \
	          -not -path "*/Index.noindex/*" 2>/dev/null | head -1); \
	 [ -z "$$APP" ] && echo "App not found in DerivedData — run 'make build' first" && exit 1; \
	 BUNDLE_ID=$$(defaults read "$$APP/Info" CFBundleIdentifier 2>/dev/null); \
	 echo "Installing $$APP…"; \
	 xcrun simctl install "$$SIM_ID" "$$APP"; \
	 echo "Launching $$BUNDLE_ID…"; \
	 xcrun simctl launch --console-pty "$$SIM_ID" "$$BUNDLE_ID"

# ── Clean ────────────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme  $(SCHEME) \
	  -configuration $(CONFIG) \
	  clean 2>/dev/null || true
	rm -rf ~/Library/Developer/Xcode/DerivedData/ChatterboxiOS-*

# ── List available simulators ────────────────────────────────────────────────

.PHONY: simulators
simulators:
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -showdestinations 2>/dev/null | grep "Simulator" | grep "name:" | \
	  sed 's/.*name:\([^,]*\).*/\1/' | sort -u

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make bootstrap          Rebuild Rust library (debug)"
	@echo "  make bootstrap-release  Rebuild Rust library (release)"
	@echo "  make build              Build the iOS app for the simulator"
	@echo "  make run                Build + boot simulator + launch app"
	@echo "  make clean              Clean Xcode build artifacts"
	@echo "  make simulators         List available simulators"
	@echo ""
	@echo "Variables:"
	@echo "  SIMULATOR   Target simulator name (default: '$(SIMULATOR)')"
	@echo "  CONFIG      Build configuration  (default: '$(CONFIG)')"
	@echo ""
	@echo "Examples:"
	@echo "  make run SIMULATOR='iPhone 15 Pro'"
	@echo "  make build CONFIG=Release"

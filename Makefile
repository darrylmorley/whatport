# WhatPort build helpers

APP = .build/WhatPort.app

.PHONY: build app run clean test

build:
	swift build

# Ask SwiftPM where it put the build rather than hard-coding the path: the
# layout changed with Xcode 27's SwiftPM, and the old folder still held a stale
# binary that this target kept bundling without complaint.
app: build
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@BIN_DIR="$$(swift build --show-bin-path)" && \
		cp "$$BIN_DIR/WhatPort" $(APP)/Contents/MacOS/WhatPort && \
		cp -R "$$BIN_DIR/WhatPort_WhatPort.bundle" $(APP)/Contents/MacOS/
	@if [ -f "Sources/WhatPort/Resources/AppIcon.png" ]; then \
		cp Sources/WhatPort/Resources/AppIcon.png $(APP)/Contents/Resources/; \
	fi
	@/usr/libexec/PlistBuddy -c "Clear dict" $(APP)/Contents/Info.plist 2>/dev/null; \
	/usr/libexec/PlistBuddy \
		-c "Add :CFBundleName string WhatPort" \
		-c "Add :CFBundleDisplayName string WhatPort" \
		-c "Add :CFBundleIdentifier string app.whatport.whatport" \
		-c "Add :CFBundleVersion string 1" \
		-c "Add :CFBundleShortVersionString string 1.0" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleExecutable string WhatPort" \
		-c "Add :LSMinimumSystemVersion string 14.0" \
		-c "Add :LSUIElement bool true" \
		-c "Add :NSPrincipalClass string NSApplication" \
		$(APP)/Contents/Info.plist
	@# Entitlements: network client needed for license key validation
	@/usr/libexec/PlistBuddy -c "Clear dict" $(APP)/Contents/entitlements.plist 2>/dev/null; \
	/usr/libexec/PlistBuddy \
		-c "Add :com.apple.security.network.client bool true" \
		$(APP)/Contents/entitlements.plist
	@# Keep-alive LaunchAgent (registered via SMAppService.agent). Real agent
	@# registration needs a properly signed app in /Applications; this dev bundle
	@# just keeps the layout in parity so the plist is always present.
	@mkdir -p $(APP)/Contents/Library/LaunchAgents
	@cp LaunchAgents/app.whatport.whatport.agent.plist $(APP)/Contents/Library/LaunchAgents/
	@echo "Built $(APP)"

run: app
	@pkill -x WhatPort 2>/dev/null || true
	@sleep 0.5
	@open $(APP)
	@echo "WhatPort running"

test:
	swift test

clean:
	swift package clean
	rm -rf $(APP)

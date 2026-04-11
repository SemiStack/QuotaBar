.PHONY: build test release install clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

install: release
	@mkdir -p QuotaBar.app/Contents/MacOS
	@mkdir -p QuotaBar.app/Contents/Resources
	@cp .build/release/QuotaBar QuotaBar.app/Contents/MacOS/
	@if [ -f Assets/Brand/app-icon-1024.png ]; then \
		cp Assets/Brand/app-icon-1024.png QuotaBar.app/Contents/Resources/; \
	fi
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>CFBundleExecutable</key>' \
		'  <string>QuotaBar</string>' \
		'  <key>CFBundleIdentifier</key>' \
		'  <string>com.quotabar.app</string>' \
		'  <key>CFBundleName</key>' \
		'  <string>QuotaBar</string>' \
		'  <key>CFBundlePackageType</key>' \
		'  <string>APPL</string>' \
		'  <key>LSMinimumSystemVersion</key>' \
		'  <string>14.0</string>' \
		'  <key>LSUIElement</key>' \
		'  <true/>' \
		'  <key>NSHighResolutionCapable</key>' \
		'  <true/>' \
		'</dict>' \
		'</plist>' > QuotaBar.app/Contents/Info.plist
	@echo "✅ QuotaBar.app created. Drag it to /Applications or run: cp -r QuotaBar.app /Applications/"

clean:
	swift package clean
	rm -rf QuotaBar.app

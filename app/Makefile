# Builds Hub.app (unsigned, ad-hoc signed for this Mac) from the SwiftPM package.
APP := build/Hub.app

.PHONY: app test clean run

app:
	swift build -c release --product HubApp
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/HubApp $(APP)/Contents/MacOS/HubApp
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

# The command-line tools sometimes miss the Swift Testing macro plugin unless it is named.
test:
	swift test -Xswiftc -plugin-path -Xswiftc $(shell xcrun --show-sdk-platform-path >/dev/null 2>&1; dirname $$(xcrun -f swift))/../lib/swift/host/plugins/testing

run: app
	open $(APP)

clean:
	rm -rf build .build

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

test:
	swift test

run: app
	open $(APP)

clean:
	rm -rf build .build

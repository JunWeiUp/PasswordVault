.PHONY: help check repo core core-release desktop desktop-test desktop-ui desktop-deploy browser browser-release android android-core android-install ios ios-core ios-test ios-install-sim ios-install-device contract bump

help: ## Show common fast-iteration commands
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

check: ## Run only the checks affected by current git changes
	python3 tool/check_changed.py

repo: ## Run fast repository & tool unit checks
	bash tool/check.sh repo

contract: ## Verify vault-core command contract across all clients
	python3 tool/core_contract.py check

bump: ## Sync all client versions: make bump V=2.5.9
	python3 tool/bump_version.py "$(V)"

core: ## Run vault-core contract, fmt, fast dev tests and clippy
	bash tool/check_native.sh core

core-release: ## Run vault-core tests in release mode (matches CI)
	PV_TEST_PROFILE=release bash tool/check_native.sh core

desktop: ## Check desktop TSX + Rust and run smoke tests
	bash tool/check_quick.sh desktop

desktop-test: ## Run a single desktop suite: make desktop-test S=notes
	bash tool/nsh_mac.sh test-fast "$(S)"

desktop-ui: ## Deploy desktop UI/TSX-only changes to /Applications (~4s)
	bash tool/macos-nsh/deploy.sh --ui-only

desktop-deploy: ## Full signed desktop deploy to /Applications
	bash tool/macos-nsh/deploy.sh --full

browser: ## Build and test the Chromium extension
	bash tool/check_native.sh browser

browser-release: ## Bump extension patch version, validate, and rebuild dist
	npm --prefix apps/browser run release:local

android-core: ## Rebuild Android arm64 vault-core bindings
	bash tool/build_mobile_core.sh android

android: ## Compile Android app + tests and run JVM unit tests
	bash tool/check_quick.sh android

android-install: ## Build matching-signature arm64 APK and install onto connected Android phone(s)
	bash tool/install_android_device.sh

ios-core: ## Rebuild iOS simulator vault-core bindings (fast host-only)
	PASSWORDVAULT_IOS_TARGETS=simulator bash tool/build_mobile_core.sh ios

ios: ## Build iOS simulator app
	bash tool/check_quick.sh ios

ios-install-sim: ## Build iOS simulator app and install onto booted simulator
	xcodegen generate --quiet --spec apps/ios/project.yml
	xcodebuild -project apps/ios/PasswordVault.xcodeproj -scheme PasswordVault -configuration Debug -derivedDataPath /tmp/pv-ios-build -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build | tail -n 10
	xcrun simctl install booted /tmp/pv-ios-build/Build/Products/Debug-iphonesimulator/PasswordVault.app

ios-install-device: ## Build personal-team iOS app and install onto connected iPhone
	bash tool/install_ios_device.sh

ios-test: ## Run iOS unit tests on the nearest simulator
	bash tool/check_quick.sh ios-test

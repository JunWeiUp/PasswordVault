.PHONY: help check repo core core-release desktop desktop-test desktop-ui desktop-deploy browser android android-core ios ios-core ios-test contract

help: ## Show common fast-iteration commands
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check: ## Run only the checks affected by current git changes
	python3 tool/check_changed.py

repo: ## Run fast repository & tool unit checks
	bash tool/check.sh repo

contract: ## Verify vault-core command contract across all clients
	python3 tool/core_contract.py check

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

android-core: ## Rebuild Android arm64 vault-core bindings
	bash tool/build_mobile_core.sh android

android: ## Compile Android app + tests and run JVM unit tests
	bash tool/check_quick.sh android

ios-core: ## Rebuild iOS simulator vault-core bindings (fast host-only)
	PASSWORDVAULT_IOS_TARGETS=simulator bash tool/build_mobile_core.sh ios

ios: ## Build iOS simulator app
	bash tool/check_quick.sh ios

ios-test: ## Run iOS unit tests on the nearest simulator
	bash tool/check_quick.sh ios-test

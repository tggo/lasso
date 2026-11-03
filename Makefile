.PHONY: native native-verify native-check test-ssh test-integration it-stop test-core
.PHONY: test-ui sim-demo
.PHONY: help bootstrap install-tools generate build build-release test test-packages test-herdrkit \
	lint format audit open clean status device archive export testflight bump-build

PROJECT := Lasso
SCHEME  := Lasso
DEST    ?= platform=iOS Simulator,name=iPhone 17 Pro

# Personal signing/App Store Connect settings live in a gitignored .env (see .env.example).
-include .env
export ASC_KEY_ID
export ASC_ISSUER_ID
TEAM_ID      ?= $(DEVELOPMENT_TEAM)
TEAM_FLAG    := $(if $(TEAM_ID),DEVELOPMENT_TEAM=$(TEAM_ID),)
ARCHIVE      := build/$(PROJECT).xcarchive
ASC_KEY_PATH := $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
ASC_AUTH     := $(if $(ASC_KEY_ID),-authenticationKeyPath $(ASC_KEY_PATH) -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID),)

help:
	@echo "Lasso — open-source iOS client for herdr"
	@echo ""
	@echo "  make bootstrap      install tools + generate project"
	@echo "  make generate       generate Xcode project (XcodeGen)"
	@echo "  make build          debug build for the simulator"
	@echo "  make test           app unit tests (simulator)"
	@echo "  make native         build OpenSSL + libssh2 from pinned source (once, ~2 min)"
	@echo "  make test-integration  SSH + herdr end-to-end on a local unprivileged sshd"
	@echo "  make test-packages  local Swift package tests (macOS, no simulator)"
	@echo "  make lint / format  SwiftLint / SwiftFormat"
	@echo "  make audit          fail on tracking SDKs, unknown hosts, unpinned deps"
	@echo "  make device         install a Release build on a connected iPhone"
	@echo "  make testflight     bump build, archive, export, upload"
	@echo "  make status         tool and project status"

install-tools:
	@command -v brew >/dev/null || { echo "❌ Homebrew required: https://brew.sh"; exit 1; }
	@for t in xcodegen swiftlint swiftformat cmake; do brew list $$t >/dev/null 2>&1 || brew install $$t; done
	@echo "✅ tools installed"

bootstrap: install-tools native generate

generate: native-check
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST)' -quiet build

build-release: generate
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(SCHEME) -configuration Release \
		-destination '$(DEST)' -quiet build

test: generate
	xcodebuild test -project $(PROJECT).xcodeproj -scheme $(SCHEME) -destination '$(DEST)' -quiet

test-herdrkit:
	swift test --package-path Packages/HerdrKit

NATIVE_OK := $(wildcard Packages/LassoSSH/Artifacts/CLibSSH2.xcframework)

# OpenSSL + libssh2 from SHA-256 pinned source (native/Sources.lock). Output is gitignored.
native:
	./native/build.sh

native-verify:
	./native/build.sh --verify-only

native-check:
	@[ -n "$(NATIVE_OK)" ] || { echo "❌ native libs missing — run: make native"; exit 1; }

test-ssh: native-check
	swift test --package-path Packages/LassoSSH

# Real SSH + real herdr: unprivileged sshd on 127.0.0.1:2222 and a throwaway herdr session.
test-integration: native-check
	@./scripts/it-sshd.sh start
	@env $$(./scripts/it-sshd.sh env) swift test --package-path Packages/LassoSSH
	@env $$(./scripts/it-sshd.sh env) swift test --package-path Packages/HerdrKit
	@env $$(./scripts/it-sshd.sh env) swift test --package-path Packages/LassoCore

it-stop:
	@./scripts/it-sshd.sh stop

test-core: native-check
	swift test --package-path Packages/LassoCore

test-packages: test-herdrkit test-ssh test-core

lint:
	swiftlint --quiet

format:
	swiftformat . --swiftversion 6.0

# The "no backdoors" gate. See SECURITY.md.
audit:
	@./scripts/audit.sh

open: generate
	open $(PROJECT).xcodeproj

clean:
	rm -rf build DerivedData .build Packages/*/.build $(PROJECT).xcodeproj

status:
	@for t in xcodegen swiftlint swiftformat xcodebuild; do command -v $$t >/dev/null && echo "  ✅ $$t" || echo "  ❌ $$t"; done
	@[ -f $(PROJECT).xcodeproj/project.pbxproj ] && echo "  ✅ project generated" || echo "  ⚠️  run make generate"
	@[ -n "$(TEAM_ID)" ] && echo "  ✅ DEVELOPMENT_TEAM set" || echo "  ⚠️  DEVELOPMENT_TEAM not set in .env (needed for device/testflight)"

# ---------------------------------------------------------------------------
# Release (requires DEVELOPMENT_TEAM, ASC_KEY_ID, ASC_ISSUER_ID in .env)
# ---------------------------------------------------------------------------
device: generate
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -allowProvisioningUpdates $(ASC_AUTH) $(TEAM_FLAG) \
		-derivedDataPath build/device build
	@ecid=$$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $$3; exit}'); \
	[ -n "$$ecid" ] || { echo "❌ No iPhone connected/unlocked."; exit 1; }; \
	xcrun devicectl device install app --device "$$ecid" build/device/Build/Products/Release-iphoneos/$(PROJECT).app

archive: generate
	@mkdir -p build
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -allowProvisioningUpdates $(ASC_AUTH) $(TEAM_FLAG) \
		-archivePath $(ARCHIVE) archive

export: archive
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>app-store-connect</string>' \
		'<key>teamID</key><string>$(TEAM_ID)</string>' \
		'<key>signingStyle</key><string>automatic</string>' \
		'<key>destination</key><string>export</string>' \
		'</dict></plist>' > build/ExportOptions.plist
	@rm -rf build/export
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath build/export \
		-exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates $(ASC_AUTH)

bump-build:
	@git diff --quiet && git diff --cached --quiet || { echo "❌ Commit or stash first."; exit 1; }
	@cur=$$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/[^0-9]//g'); nxt=$$((cur + 1)); \
	sed -i '' "s/CURRENT_PROJECT_VERSION: \"$$cur\"/CURRENT_PROJECT_VERSION: \"$$nxt\"/" project.yml; \
	git add project.yml && git commit -q -m "chore: Build $$nxt" && echo "🔢 build $$cur → $$nxt"

testflight: bump-build export
	@[ -n "$(ASC_KEY_ID)" ] && [ -n "$(ASC_ISSUER_ID)" ] || { echo "❌ Set ASC_KEY_ID and ASC_ISSUER_ID in .env"; exit 1; }
	xcrun altool --upload-app -f build/export/$(PROJECT).ipa -t ios --apiKey $(ASC_KEY_ID) --apiIssuer $(ASC_ISSUER_ID)

# --- git-dod auto-install ----------------------------------------------------
# ANY `make` invocation installs the commit-msg hook if it is missing. Idempotent:
# once the symlink exists this is a cheap `test -L` no-op. Because developers run
# `make test` / `lint` / `build` before pushing, the hard gate is effectively always
# on — nobody has to remember an install step.
#
# It also pins a LOCAL core.hooksPath, which overrides a GLOBAL one (a developer
# with `git config --global core.hooksPath ~/.git-hooks` would otherwise have the
# repo hook silently shadowed and never fire).
#
# NOTE: local hooks are always bypassable (`git commit --no-verify`); the advisory
# layer is CI — see .github/workflows/verify-commits.yml (non-blocking).
__install_hooks := $(shell \
	gd="$$(git rev-parse --absolute-git-dir 2>/dev/null)"; \
	if [ -n "$$gd" ] && [ ! -L "$$gd/hooks/commit-msg" ] && [ -f .githooks/commit-msg ]; then \
		mkdir -p "$$gd/hooks"; \
		git config --local core.hooksPath "$$gd/hooks" 2>/dev/null; \
		ln -sf "$(CURDIR)/.githooks/commit-msg" "$$gd/hooks/commit-msg" 2>/dev/null; \
		chmod +x .githooks/commit-msg .claude/hooks/dod_reminder.sh 2>/dev/null; \
	fi; true)

.PHONY: hooks
hooks:
	@hd="$$(git rev-parse --absolute-git-dir)/hooks"; \
	git config --local core.hooksPath "$$hd"; \
	mkdir -p "$$hd"; \
	ln -sf "$(CURDIR)/.githooks/commit-msg" "$$hd/commit-msg"; \
	chmod +x .githooks/commit-msg .claude/hooks/dod_reminder.sh 2>/dev/null || true; \
	echo "✓ git-dod: commit-msg -> .githooks/commit-msg (hooksPath=$$hd)"
# --- end git-dod -------------------------------------------------------------

sim-demo: generate
	./scripts/sim-demo.sh

# Full UI flow on the simulator against local sshd + herdr. Screenshots -> build/shots/.
test-ui: generate
	@./scripts/sim-demo.sh >/dev/null
	@mkdir -p build/shots
	@env $$(./scripts/it-sshd.sh env | sed -E 's/(^| )LASSO_/\1TEST_RUNNER_LASSO_/g') TEST_RUNNER_LASSO_SHOTS=$(CURDIR)/build/shots \
		xcodebuild test -project $(PROJECT).xcodeproj -scheme LassoUI -destination '$(DEST)' -quiet

.DEFAULT_GOAL := app
INSTALL_DIR ?= /Applications

.PHONY: all app release install clean run
all: app

app:
	bash scripts/build-app.sh

release: app
	bash scripts/package-release.sh

install: app
	bash scripts/install-app.sh "$(INSTALL_DIR)"

clean:
	rm -rf .build build dist

run:
	bash scripts/build-rust-helpers.sh
	swift build --arch arm64 --product termvia-askpass
	swift build --arch arm64 --product termvia-proxy
	install -m 755 .build/rust/aarch64-apple-darwin/release/termvia-ppk \
		.build/rust/aarch64-apple-darwin/release/termvia-wireguard "$$(swift build --arch arm64 --show-bin-path)/"
	swift run --arch arm64 Termvia

# Optional local checks are excluded from source releases.
-include .local.mk

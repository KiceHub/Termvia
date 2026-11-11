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
	bash scripts/build-ppk.sh
	swift build --arch arm64 --product termvia-askpass
	install -m 755 .build/ppk-build/puttygen "$$(swift build --arch arm64 --show-bin-path)/termvia-ppk"
	swift run --arch arm64 Termvia

# Optional local checks are excluded from source releases.
-include .local.mk

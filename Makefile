# Task front-door. `make install` builds the release app and puts the CLI +
# app bundle on your PATH (Homebrew prefix when available, /usr/local otherwise).
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)
BINDIR  = $(PREFIX)/bin

.PHONY: build test app universal install uninstall clean

build:
	swift build -c release

test:
	swift test

# labelkit.app must end up next to the binary: the bare CLI relaunches
# through the sibling bundle for LaunchServices activation (window focus
# when launched from a terminal).
app:
	./scripts/package-app.sh

universal:
	./scripts/package-app.sh --universal

install: app
	install -d "$(BINDIR)"
	install .build/release/labelkit "$(BINDIR)/labelkit"
	rm -rf "$(BINDIR)/labelkit.app"
	cp -R .build/release/labelkit.app "$(BINDIR)/labelkit.app"
	@echo "installed $(BINDIR)/labelkit"

uninstall:
	rm -f "$(BINDIR)/labelkit"
	rm -rf "$(BINDIR)/labelkit.app"

clean:
	swift package clean

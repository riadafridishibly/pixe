PREFIX ?= /usr/local
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO := Sources/Pixe/BuildInfo.swift

.PHONY: build install uninstall clean

build:
	@echo 'enum BuildInfo { static let version = "0.1.0"; static let commit = "$(COMMIT)" }' > $(BUILD_INFO)
	swift build -c release
	@git checkout -- $(BUILD_INFO) 2>/dev/null || true

install: build
	install -d $(PREFIX)/bin
	install .build/release/pixe $(PREFIX)/bin/pixe

uninstall:
	rm -f $(PREFIX)/bin/pixe

clean:
	swift package clean

# keyouse — build / install / run from the terminal.
# ponytail: a bare release binary is enough for terminal use; add a signed .app only when distributing.

PREFIX ?= /usr/local
BIN    := .build/release/keyouse

.PHONY: build run install uninstall clean

build:
	swift build -c release

run: build
	$(BIN)

# Copy the release binary onto PATH so you can just type `keyouse` anywhere.
# /usr/local/bin needs sudo; TCC note: run from Terminal — permission attributes to Terminal.app.
install: build
	sudo install -d $(PREFIX)/bin
	sudo install -m 0755 $(BIN) $(PREFIX)/bin/keyouse
	@echo "설치됨: $(PREFIX)/bin/keyouse  —  터미널에서 'keyouse' 로 실행"

uninstall:
	sudo rm -f $(PREFIX)/bin/keyouse

clean:
	swift package clean

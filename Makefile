VERSION  := 1.0
APP      := Mem.app
HELPER   := memread
CLI      := mem
BINDIR   ?= $(HOME)/.local/bin
PREFIX   := /usr/local/libexec
ZIP      := dist/Mem-$(VERSION).zip

.PHONY: all install install-cli install-helper uninstall package dump clean

all: $(APP) $(HELPER) $(CLI)

Mem.icns: icon.swift
	swift icon.swift Mem.iconset && iconutil -c icns Mem.iconset -o $@ && rm -rf Mem.iconset

$(APP): main.swift Info.plist Mem.icns
	rm -rf $@ && mkdir -p $@/Contents/MacOS
	swiftc -O -whole-module-optimization main.swift -o $@/Contents/MacOS/Mem
	sed "s/VERSION/$(VERSION)/" Info.plist > $@/Contents/Info.plist
	mkdir -p $@/Contents/Resources && cp Mem.icns $@/Contents/Resources/
	codesign --force --sign - $@

$(HELPER): memread.c
	cc -O2 -Wall -o $@ $<

$(CLI): mem.c
	cc -O2 -Wall -Wextra -o $@ $<

# Copy Mem.app to ~/Applications.
install: $(APP)
	mkdir -p ~/Applications && rm -rf ~/Applications/$(APP) && cp -R $(APP) ~/Applications/

# Copy the mem CLI to $(BINDIR) (override: make install-cli BINDIR=/usr/local/bin).
install-cli: $(CLI)
	mkdir -p $(BINDIR) && install -m 755 $(CLI) $(BINDIR)/$(CLI)

# One-time (rerun only if memread.c changes): setuid root so Mem can read
# root-owned processes without running top. Asks for your password.
install-helper: $(HELPER)
	sudo mkdir -p $(PREFIX)
	sudo install -o root -g wheel -m 4755 $(HELPER) $(PREFIX)/$(HELPER)

uninstall:
	rm -rf ~/Applications/$(APP) $(BINDIR)/$(CLI)
	sudo rm -f $(PREFIX)/$(HELPER)

package: $(ZIP)

$(ZIP): $(APP) $(HELPER) $(CLI)
	mkdir -p dist && rm -f $@
	ditto -c -k --norsrc --noextattr --keepParent $(APP) $@
	zip -qj $@ $(HELPER) $(CLI)

# Print totals and the top processes, for checking numbers against top.
dump: $(APP)
	./$(APP)/Contents/MacOS/Mem --dump

clean:
	rm -rf $(APP) $(HELPER) $(CLI) Mem.icns dist

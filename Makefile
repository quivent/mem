VERSION  := 1.0
APP      := Mem.app
HELPER   := memread
PREFIX   := /usr/local/libexec
ZIP      := dist/Mem-$(VERSION).zip

.PHONY: all install install-helper uninstall package dump clean

all: $(APP) $(HELPER)

$(APP): main.swift Info.plist
	rm -rf $@ && mkdir -p $@/Contents/MacOS
	swiftc -O -whole-module-optimization main.swift -o $@/Contents/MacOS/Mem
	sed "s/VERSION/$(VERSION)/" Info.plist > $@/Contents/Info.plist
	codesign --force --sign - $@

$(HELPER): memread.c
	cc -O2 -Wall -o $@ $<

# Copy Mem.app to ~/Applications.
install: $(APP)
	mkdir -p ~/Applications && rm -rf ~/Applications/$(APP) && cp -R $(APP) ~/Applications/

# One-time (rerun only if memread.c changes): setuid root so Mem can read
# root-owned processes without running top. Asks for your password.
install-helper: $(HELPER)
	sudo mkdir -p $(PREFIX)
	sudo install -o root -g wheel -m 4755 $(HELPER) $(PREFIX)/$(HELPER)

uninstall:
	rm -rf ~/Applications/$(APP)
	sudo rm -f $(PREFIX)/$(HELPER)

package: $(ZIP)

$(ZIP): $(APP) $(HELPER)
	mkdir -p dist && rm -f $@
	ditto -c -k --norsrc --noextattr --keepParent $(APP) $@
	zip -qj $@ $(HELPER)

# Print totals and the top processes, for checking numbers against top.
dump: $(APP)
	./$(APP)/Contents/MacOS/Mem --dump

clean:
	rm -rf $(APP) $(HELPER) dist

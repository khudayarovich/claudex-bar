APP        := build/ClaudexBar.app
EXE        := $(APP)/Contents/MacOS/ClaudexBar
INSTALLED  := $(HOME)/Applications/ClaudexBar.app
LOGS       := build/logs

.PHONY: build debug test run demo snapshot install uninstall kill cpu probe clean

build:
	@Scripts/build-app.sh

debug:
	@CONFIG=debug Scripts/build-app.sh

test:
	swift test

kill:
	@pkill -x ClaudexBar 2>/dev/null || true

run: build kill
	@mkdir -p $(LOGS)
	open -n $(APP) --stdout $(abspath $(LOGS))/out.log --stderr $(abspath $(LOGS))/err.log

demo: build kill
	@mkdir -p $(LOGS)
	open -n $(APP) --stdout $(abspath $(LOGS))/out.log --stderr $(abspath $(LOGS))/err.log --args --demo --debug-commands

snapshot: build
	@rm -rf build/snapshots && mkdir -p build/snapshots
	$(EXE) --snapshot $(abspath build/snapshots)

install: build kill
	@mkdir -p $(HOME)/Applications
	@rm -rf $(INSTALLED)
	ditto $(APP) $(INSTALLED)
	open $(INSTALLED)

uninstall: kill
	rm -rf $(INSTALLED)

cpu:
	@PID=$$(pgrep -x ClaudexBar | head -1); \
	if [ -z "$$PID" ]; then echo "ClaudexBar is not running"; exit 1; fi; \
	top -l 13 -s 5 -pid $$PID -stats pid,command,cpu,idlew,mem | awk 'NR==1 || /ClaudexBar/'

probe:
	swift run claudex-probe $(ARGS)

clean:
	rm -rf build .build

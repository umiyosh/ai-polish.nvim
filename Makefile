NVIM ?= nvim

.PHONY: test lint fmt fmt-check check

test:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ai-polish { minimal_init = 'tests/minimal_init.lua', sequential = true }"

lint:
	luacheck lua plugin tests

fmt:
	stylua lua plugin tests

fmt-check:
	stylua --check lua plugin tests

check: lint fmt-check test

.PHONY: test lint format check

test:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/comet { minimal_init = 'tests/minimal_init.lua' }"

lint:
	luac -p lua/comet/*.lua lua/comet/ui/*.lua plugin/*.lua tests/comet/*.lua

format:
	stylua lua/ tests/ plugin/

check:
	stylua --check lua/ tests/ plugin/

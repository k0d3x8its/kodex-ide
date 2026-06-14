# kodex-ide — headless test harness.
# `make test` runs every tests/*_spec.lua under `nvim --headless -u NONE`.

.PHONY: test
test:
	@bash tests/run.sh

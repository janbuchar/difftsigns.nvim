.PHONY: test

# Run the full test suite headlessly with plenary. --clean keeps the user's
# personal config (and its colorscheme errors) out of the run.
test:
	nvim --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

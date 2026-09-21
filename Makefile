.PHONY: test demo

# Run the full test suite headlessly with plenary. --clean keeps the user's
# personal config (and its colorscheme errors) out of the run.
test:
	nvim --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

# Re-render demo/demo.gif. Everything runs in a container so the output does
# not depend on the host's fonts, colourscheme or plugin versions.
demo:
	docker build -t difftsigns-demo demo
	docker run --rm -v "$(CURDIR):/plugin:ro" -v "$(CURDIR)/demo:/out" difftsigns-demo /out/demo.tape

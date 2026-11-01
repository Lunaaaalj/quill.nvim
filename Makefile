.PHONY: test

# Fresh XDG dirs: no user config, and caches/state go to a throwaway dir.
test:
	@d=$$(mktemp -d) && \
	XDG_CONFIG_HOME=$$d/config XDG_DATA_HOME=$$d/data XDG_STATE_HOME=$$d/state XDG_CACHE_HOME=$$d/cache \
	nvim --headless --clean -c "luafile tests/run.lua"; s=$$?; rm -rf $$d; exit $$s

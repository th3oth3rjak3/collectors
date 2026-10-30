.PHONY: test

test:
	zig test src/root.zig 2>&1 | cat

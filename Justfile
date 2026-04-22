# Induct development commands

# Build the project
build:
    zig build

# Run all tests
test:
    zig build test

# --- Zig style checker (vendored from ~/dotfiles/zig-tools) ---
#
# `just lint` compares the current source tree against
# scripts/style_baseline.txt and fails only on regressions. Run
# `just lint-update-baseline` after draining violations. Override the
# checker path with ZIG_STYLE_CHECKER when needed.

style_checker := env("ZIG_STYLE_CHECKER", "scripts/check_style.zig")

fmt-check:
    zig fmt --check src

lint:
    zig run {{style_checker}} -- --root src

lint-strict:
    zig run {{style_checker}} -- --root src --strict

lint-update-baseline:
    zig run {{style_checker}} -- --root src --update-baseline

# --- end zig-tools linter ---

# Install induct to ~/.local/bin
install: build
    mkdir -p ~/.local/bin
    cp zig-out/bin/induct ~/.local/bin/induct
    @echo "Installed to ~/.local/bin/induct"

# Uninstall from ~/.local/bin
uninstall:
    rm -f ~/.local/bin/induct
    @echo "Removed ~/.local/bin/induct"

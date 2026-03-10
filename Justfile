# Induct development commands

# Build the project
build:
    zig build

# Run all tests
test:
    zig build test

# Install induct to ~/.local/bin
install: build
    mkdir -p ~/.local/bin
    cp zig-out/bin/induct ~/.local/bin/induct
    @echo "Installed to ~/.local/bin/induct"

# Uninstall from ~/.local/bin
uninstall:
    rm -f ~/.local/bin/induct
    @echo "Removed ~/.local/bin/induct"

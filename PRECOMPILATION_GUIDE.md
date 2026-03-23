# Precompilation Guide

Exclosured lets you write Rust code that compiles to WebAssembly and runs
in the user's browser. But every consumer of your library needs the Rust
toolchain installed to compile the WASM modules. This guide shows how to
precompile the WASM once and distribute it via GitHub Releases, so your
users never need Rust.

## Why precompile?

Without precompilation, every `mix compile` needs:
- Rust (`rustc`, `cargo`)
- The `wasm32-unknown-unknown` target
- `wasm-bindgen-cli`

With precompilation, consumers just run `mix compile` and the prebuilt
`.wasm` and `.js` files are downloaded automatically.

Since Exclosured targets only `wasm32-unknown-unknown`, there is exactly
**one build artifact per module**. No cross-compilation matrix, no
platform detection, no NIF version compatibility.

## Step 1: Set up your library

Your library should use Exclosured to define WASM modules, either via
`defwasm` (inline) or a full Cargo workspace.

```elixir
# mix.exs
def deps do
  [
    {:exclosured, "~> 0.1.1"},
    {:exclosured_precompiled, "~> 0.1.0"}
  ]
end
```

## Step 2: Create the precompiled module

Define a module that tells `ExclosuredPrecompiled` where to find the
prebuilt archives:

```elixir
defmodule MyLibrary.Precompiled do
  use ExclosuredPrecompiled,
    otp_app: :my_library,
    base_url: "https://github.com/USER/my_library/releases/download/v0.1.0",
    version: "0.1.0",
    modules: [:my_processor, :my_filter]
end
```

The `base_url` points to a GitHub Release. Each module's archive is
expected at `BASE_URL/MODULE-vVERSION-wasm32.tar.gz`.

## Step 3: Build and package

One command compiles from source and packages into archives. Modules
are auto-discovered from your `ExclosuredPrecompiled` config:

```sh
mix exclosured_precompiled.precompile --version 0.1.0
```

This creates one `.tar.gz` per module in `_build/precompiled/`:

```
_build/precompiled/
  my_processor-v0.1.0-wasm32.tar.gz
  my_filter-v0.1.0-wasm32.tar.gz
```

Each archive contains the wasm-bindgen output files:

```
my_processor_bg.wasm       # compiled WASM binary
my_processor.js            # wasm-bindgen JS shim
my_processor.d.ts          # TypeScript definitions (if present)
my_processor_bg.wasm.d.ts  # WASM TypeScript definitions (if present)
```

## Step 4: Upload to GitHub Release

Create a GitHub Release and upload the archives:

```sh
gh release create v0.1.0 _build/precompiled/*.tar.gz
```

Or upload manually through the GitHub web UI.

## Step 5: Generate checksums

After uploading, generate checksums to verify download integrity:

```sh
# From local archives (preferred, avoids extra download):
mix exclosured_precompiled.checksum \
  --local \
  --dir _build/precompiled \
  --module MyLibrary.Precompiled

# Or download from GitHub and compute:
mix exclosured_precompiled.checksum \
  --base-url https://github.com/USER/my_library/releases/download/v0.1.0 \
  --module MyLibrary.Precompiled
```

This generates `checksum-Elixir.MyLibrary.Precompiled.exs` in your
project root.

## Step 6: Publish to Hex

Include the checksum file in your Hex package:

```elixir
defp package do
  [
    files: ~w(lib priv mix.exs README.md LICENSE checksum-*.exs),
    licenses: ["MIT"],
    links: %{"GitHub" => "https://github.com/USER/my_library"}
  ]
end
```

Publish:

```sh
mix hex.publish
```

## For consumers

Your users just add the dependency:

```elixir
def deps do
  [{:my_library, "~> 0.1.0"}]
end
```

On `mix compile`, `ExclosuredPrecompiled` will:

1. Check if WASM files exist in `priv/static/wasm/MODULE/`
2. If not, download `MODULE-vVERSION-wasm32.tar.gz` from your GitHub
   Release
3. Verify the SHA-256 checksum against the checksum file
4. Extract the files and write `.sha256` sidecar files

No Rust toolchain needed.

## CI automation

You can automate the entire process in GitHub Actions:

```yaml
name: Release
on:
  push:
    tags: ["v*"]

jobs:
  precompile:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.17"
          otp-version: "27"

      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: wasm32-unknown-unknown

      - name: Install wasm-bindgen-cli
        run: cargo install wasm-bindgen-cli

      - name: Build and package
        run: |
          mix deps.get
          mix compile
          mix exclosured_precompiled.precompile \
            --version ${{ github.ref_name }} \
            --modules my_processor,my_filter

      - name: Generate checksums
        run: |
          mix exclosured_precompiled.checksum \
            --local \
            --dir _build/precompiled \
            --module MyLibrary.Precompiled

      - name: Upload to GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: _build/precompiled/*.tar.gz

      - name: Publish to Hex
        env:
          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
        run: mix hex.publish --yes
```

## Environment variables

| Variable | Purpose |
|---|---|
| `EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL` | Set to `"1"` or `"true"` to skip downloads and build from source |
| `EXCLOSURED_PRECOMPILED_GLOBAL_CACHE_PATH` | Override cache directory (useful for NixOS) |
| `HTTP_PROXY` / `http_proxy` | HTTP proxy for downloads |
| `HTTPS_PROXY` / `https_proxy` | HTTPS proxy for downloads |
| `HEX_CACERTS_PATH` | Custom CA certificates file |
| `MIX_XDG` | Use Linux XDG base directories for cache |

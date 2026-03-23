# Exclosured Precompiled

[![Hex.pm](https://img.shields.io/hexpm/v/exclosured_precompiled)](https://hex.pm/packages/exclosured_precompiled)

This project makes it easy to distribute precompiled WASM modules for
libraries built with [Exclosured](https://github.com/cocoa-xu/exclosured).

With Exclosured Precompiled, library consumers do not need the Rust
toolchain, `cargo`, or `wasm-bindgen` installed. The precompiled `.wasm`
and `.js` files are downloaded from a GitHub Release during `mix compile`.

Since all Exclosured modules compile to `wasm32-unknown-unknown`, there
is only **one compilation target** per module. No platform detection or
cross-compilation matrix needed.

Check the [documentation](https://hexdocs.pm/exclosured_precompiled) for
API details and the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for
a step-by-step walkthrough including CI automation.

## Installation

```elixir
def deps do
  [
    {:exclosured_precompiled, "~> 0.1.0"}
  ]
end
```

## Guide for Library Authors

### 1. Add dependencies

Your library needs both `exclosured` (for compilation) and
`exclosured_precompiled` (for distribution):

```elixir
def deps do
  [
    {:exclosured, "~> 0.1.1"},
    {:exclosured_precompiled, "~> 0.1.0"}
  ]
end
```

### 2. Create a precompiled module

Define a module that declares which WASM modules should be downloaded
and where to find them:

```elixir
defmodule MyLibrary.Precompiled do
  use ExclosuredPrecompiled,
    otp_app: :my_library,
    base_url: "https://github.com/user/my_library/releases/download/v0.1.0",
    version: "0.1.0",
    modules: [:my_processor, :my_filter]
end
```

### 3. Build and package

Compile the WASM modules locally (requires the Rust toolchain), then
package them into archives:

```sh
mix compile
mix exclosured_precompiled.precompile --version 0.1.0 --modules my_processor,my_filter
```

This creates one `.tar.gz` and one `.sha256` per module in `_build/precompiled/`:

```
_build/precompiled/
  my_processor-v0.1.0-wasm32.tar.gz
  my_processor-v0.1.0-wasm32.tar.gz.sha256
  my_filter-v0.1.0-wasm32.tar.gz
  my_filter-v0.1.0-wasm32.tar.gz.sha256
```

Each archive contains the wasm-bindgen output:

```
my_processor-v0.1.0-wasm32.tar.gz
  my_processor_bg.wasm       # compiled WASM binary
  my_processor.js            # wasm-bindgen JS shim
  my_processor.d.ts          # TypeScript definitions (if present)
  my_processor_bg.wasm.d.ts  # WASM TypeScript definitions (if present)
```

### 4. Upload to GitHub Release

Upload both archives and their `.sha256` sidecar files:

```sh
gh release create v0.1.0 _build/precompiled/*.tar.gz _build/precompiled/*.sha256
```

### 5. Generate checksums

Generate a checksum file for inclusion in your Hex package. This
ensures download integrity for consumers.

```sh
# From local archives (reads .sha256 sidecar files):
mix exclosured_precompiled.checksum \
  --local \
  --dir _build/precompiled \
  --module MyLibrary.Precompiled

# Or from GitHub Release (downloads only the small .sha256 files,
# not the full archives):
mix exclosured_precompiled.checksum \
  --base-url https://github.com/user/my_library/releases/download/v0.1.0 \
  --module MyLibrary.Precompiled
```

This generates `checksum-Elixir.MyLibrary.Precompiled.exs` in the
project root.

### 6. Publish to Hex

Include the checksum file in your package:

```elixir
defp package do
  [
    files: ~w(lib priv mix.exs README.md LICENSE checksum-*.exs)
  ]
end
```

Then publish:

```sh
mix hex.publish
```

## Guide for Library Consumers

Just add the library to your dependencies. The WASM files are
downloaded automatically during `mix compile`:

```elixir
def deps do
  [{:my_library, "~> 0.1.0"}]
end
```

No Rust, `cargo`, or `wasm-bindgen` installation needed.

### Force build from source

If you want to compile from source instead of downloading precompiled
WASM (e.g., for development or auditing):

```elixir
# In config/config.exs:
config :exclosured_precompiled, force_build: true

# Or for specific modules only:
config :exclosured_precompiled, force_build: [:my_processor]
```

Or via environment variable:

```sh
EXCLOSURED_PRECOMPILED_FORCE_BUILD=1 mix compile
```

This requires the Rust toolchain to be installed.

## How It Works

1. At compile time, `ExclosuredPrecompiled` checks if the WASM files
   exist in `priv/static/wasm/MODULE/`
2. If missing, downloads `MODULE-vVERSION-wasm32.tar.gz` from the
   GitHub Release URL specified by the library author
3. Verifies the SHA-256 checksum against the checksum file shipped
   with the Hex package
4. Extracts `.wasm` and `.js` files to `priv/static/wasm/MODULE/`
5. Writes `.sha256` files next to each extracted file for independent
   verification

Downloaded archives are cached in a user-level cache directory
(`~/Library/Caches` on macOS, `~/.cache` on Linux) to avoid redundant
downloads across projects.

## Environment Variables

| Variable | Purpose |
|---|---|
| `EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL` | Set to `"1"` or `"true"` to skip downloads and build from source |
| `EXCLOSURED_PRECOMPILED_GLOBAL_CACHE_PATH` | Override the cache directory (useful for NixOS) |
| `HTTP_PROXY` / `http_proxy` | HTTP proxy for downloads |
| `HTTPS_PROXY` / `https_proxy` | HTTPS proxy for downloads |
| `HEX_CACERTS_PATH` | Custom CA certificate bundle for HTTPS |
| `MIX_XDG` | Use Linux XDG base directories for cache |

## Differences from Rustler Precompiled

| | Rustler Precompiled | Exclosured Precompiled |
|---|---|---|
| Artifact type | NIF `.so`/`.dll` | WASM `.wasm` + `.js` |
| Targets | ~20+ (OS x arch x NIF version) | 1 (`wasm32-unknown-unknown`) |
| Platform detection | Complex (OS, arch, ABI, NIF version) | None needed |
| Variants | Yes (glibc versions, CPU features) | None needed |
| Where it runs | Server (BEAM VM) | Browser (WebAssembly) |

The single-target design makes Exclosured Precompiled significantly
simpler: no cross-compilation matrix, no platform detection, no
variant resolution.

## Acknowledgements

This project is inspired by [Rustler Precompiled](https://github.com/philss/rustler_precompiled)
by Philip Sampaio. The design of the checksum verification, caching,
and download-with-retry mechanisms follows patterns established in that
project. Adapted for Exclosured's single-target WASM use case.

## License

Copyright 2025 Cocoa Xu

Licensed under the MIT License. See [LICENSE](LICENSE) for details.

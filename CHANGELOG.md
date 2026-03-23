# Changelog

## 0.1.0

Initial release.

- `use ExclosuredPrecompiled` macro for declaring precompiled WASM modules
- Automatic download from GitHub Releases during `mix compile`
- SHA-256 checksum verification against checksum file shipped with Hex package
- Per-file `.sha256` sidecar files written after extraction
- Download retry with exponential backoff (3 attempts)
- HTTP/HTTPS redirect following (301/302/303/307/308)
- HTTP/HTTPS proxy support (`HTTP_PROXY`, `HTTPS_PROXY`)
- Global cache directory with platform-aware defaults (macOS, Linux, Windows)
- `EXCLOSURED_PRECOMPILED_GLOBAL_CACHE_PATH` for NixOS and air-gapped environments
- `EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL` to skip downloads and build from source
- `force_build: true` and `force_build: [:module]` config options
- `mix exclosured_precompiled.precompile` task for packaging WASM into `.tar.gz` archives with `.sha256` sidecars
- `mix exclosured_precompiled.checksum` task for generating checksum files (reads `.sha256` sidecars instead of downloading full archives)
- CA certificate support via `HEX_CACERTS_PATH` or CAStore
- `MIX_XDG` support for Linux XDG base directories
- [Precompilation Guide](PRECOMPILATION_GUIDE.md) with CI automation example

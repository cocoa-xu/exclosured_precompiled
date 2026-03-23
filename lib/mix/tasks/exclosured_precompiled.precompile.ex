defmodule Mix.Tasks.ExclosuredPrecompiled.Precompile do
  @moduledoc """
  Compile WASM modules and package them into tar.gz archives for
  publishing to a GitHub Release.

  ## Usage

      mix exclosured_precompiled.precompile --version 0.1.0 --modules my_processor,my_filter

  ## Options

    * `--version` (required) - The version string for the archive filename
    * `--modules` (required) - Comma-separated list of module names to package
    * `--wasm-dir` - Base directory for WASM files (default: `priv/static/wasm`)
    * `--output-dir` - Where to write archives (default: `_build/precompiled`)

  ## Output

  Creates one `.tar.gz` file per module in the output directory:

      _build/precompiled/my_processor-v0.1.0-wasm32.tar.gz
      _build/precompiled/my_filter-v0.1.0-wasm32.tar.gz

  Upload these to your GitHub Release, then run
  `mix exclosured_precompiled.checksum` to generate checksums.
  """

  use Mix.Task

  @shortdoc "Compile and package WASM modules for precompiled distribution"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          version: :string,
          modules: :string,
          wasm_dir: :string,
          output_dir: :string
        ]
      )

    version = opts[:version] || Mix.raise("--version is required")
    modules_str = opts[:modules] || Mix.raise("--modules is required")
    modules = modules_str |> String.split(",") |> Enum.map(&String.trim/1)

    wasm_base = opts[:wasm_dir] || "priv/static/wasm"
    output_dir = opts[:output_dir] || "_build/precompiled"

    for module_name <- modules do
      wasm_dir = Path.join(wasm_base, module_name)

      path =
        ExclosuredPrecompiled.package_module(module_name, version,
          wasm_dir: wasm_dir,
          output_dir: output_dir
        )

      size = File.stat!(path).size
      Mix.shell().info("  #{path} (#{div(size, 1024)} KB)")
    end

    Mix.shell().info("\nUpload archives and checksums to your GitHub Release:")

    Mix.shell().info(
      "  gh release create v#{version} #{output_dir}/*.tar.gz #{output_dir}/*.sha256"
    )
  end
end

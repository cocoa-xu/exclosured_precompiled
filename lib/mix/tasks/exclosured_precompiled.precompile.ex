defmodule Mix.Tasks.ExclosuredPrecompiled.Precompile do
  @moduledoc """
  Compile WASM modules and package them into tar.gz archives for
  publishing to a GitHub Release.

  This task automatically builds from source (skipping precompiled
  downloads) and packages the results.

  ## Usage

      # Auto-discover everything from mix.exs and ExclosuredPrecompiled config:
      mix exclosured_precompiled.precompile

      # Or override version and modules:
      mix exclosured_precompiled.precompile --version 0.1.0 --modules my_processor,my_filter

  ## Options

    * `--version` - The version string for the archive filename.
      Defaults to the project version from `mix.exs`.
    * `--modules` - Comma-separated list of module names to package.
      If omitted, auto-discovers from modules using `ExclosuredPrecompiled`.
    * `--wasm-dir` - Base directory for WASM files (default: `priv/static/wasm`)
    * `--output-dir` - Where to write archives (default: `_build/precompiled`)

  ## Output

  Creates one `.tar.gz` and `.sha256` file per module in the output directory.
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

    wasm_base = opts[:wasm_dir] || "priv/static/wasm"
    output_dir = opts[:output_dir] || "_build/precompiled"

    # Force build from source (skip precompiled download)
    ExclosuredPrecompiled.set_force_build_all(true)

    # Compile the project to build WASM modules
    Mix.shell().info("[ExclosuredPrecompiled] Compiling WASM modules from source...")
    Mix.Task.run("compile", ["--force"])

    # Discover config or use provided overrides
    {version, modules} = resolve_version_and_modules(opts)

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
  end

  defp resolve_version_and_modules(opts) do
    case {opts[:version], opts[:modules]} do
      {nil, nil} ->
        # Auto-discover both from ExclosuredPrecompiled config
        config = discover_config()
        {config.version, Enum.map(config.modules, &to_string/1)}

      {version, nil} ->
        # Version provided, discover modules
        config = discover_config()
        {version, Enum.map(config.modules, &to_string/1)}

      {nil, modules_str} ->
        # Modules provided, discover version
        config = discover_config()
        modules = modules_str |> String.split(",") |> Enum.map(&String.trim/1)
        {config.version, modules}

      {version, modules_str} ->
        # Both provided
        modules = modules_str |> String.split(",") |> Enum.map(&String.trim/1)
        {version, modules}
    end
  end

  defp discover_config do
    app = Mix.Project.config()[:app]

    config =
      case :application.get_key(app, :modules) do
        {:ok, modules} ->
          modules
          |> Enum.find(fn mod ->
            Code.ensure_loaded?(mod) and
              function_exported?(mod, :__exclosured_precompiled_config__, 0)
          end)
          |> case do
            nil -> nil
            mod -> mod.__exclosured_precompiled_config__()
          end

        :undefined ->
          nil
      end

    config ||
      Mix.raise(
        "[ExclosuredPrecompiled] No module with `use ExclosuredPrecompiled` found. " <>
          "Pass --version and --modules explicitly."
      )
  end
end

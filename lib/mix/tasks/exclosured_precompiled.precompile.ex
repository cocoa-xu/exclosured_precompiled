defmodule Mix.Tasks.ExclosuredPrecompiled.Precompile do
  @moduledoc """
  Compile WASM modules and package them into tar.gz archives for
  publishing to a GitHub Release.

  This task automatically builds from source (skipping precompiled
  downloads) and packages the results.

  ## Usage

      # Auto-discover modules from ExclosuredPrecompiled config:
      mix exclosured_precompiled.precompile --version 0.1.0

      # Or specify modules manually:
      mix exclosured_precompiled.precompile --version 0.1.0 --modules my_processor,my_filter

  ## Options

    * `--version` (required) - The version string for the archive filename
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

    version = opts[:version] || Mix.raise("--version is required")

    wasm_base = opts[:wasm_dir] || "priv/static/wasm"
    output_dir = opts[:output_dir] || "_build/precompiled"

    # Force build from source (skip precompiled download)
    ExclosuredPrecompiled.set_force_build_all(true)

    # Compile the project to build WASM modules
    Mix.shell().info("[ExclosuredPrecompiled] Compiling WASM modules from source...")
    Mix.Task.run("compile", ["--force"])

    # Discover or use provided modules
    modules =
      case opts[:modules] do
        nil ->
          discovered = discover_modules()

          if discovered == [] do
            Mix.raise(
              "[ExclosuredPrecompiled] No modules found. " <>
                "Either pass --modules or define a module with `use ExclosuredPrecompiled`."
            )
          end

          Mix.shell().info(
            "[ExclosuredPrecompiled] Discovered modules: #{Enum.join(discovered, ", ")}"
          )

          discovered

        modules_str ->
          modules_str |> String.split(",") |> Enum.map(&String.trim/1)
      end

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

  defp discover_modules do
    app = Mix.Project.config()[:app]

    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(fn mod ->
          Code.ensure_loaded?(mod) and
            function_exported?(mod, :__exclosured_precompiled_config__, 0)
        end)
        |> Enum.flat_map(fn mod ->
          config = mod.__exclosured_precompiled_config__()
          Enum.map(config.modules, &to_string/1)
        end)
        |> Enum.uniq()

      :undefined ->
        []
    end
  end
end

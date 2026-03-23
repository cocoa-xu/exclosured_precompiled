defmodule Mix.Tasks.ExclosuredPrecompiled.Checksum do
  @moduledoc """
  Generate checksums for precompiled WASM archives.

  ## Usage

  From local archives (after running `exclosured_precompiled.precompile`):

      mix exclosured_precompiled.checksum --local

  From a GitHub Release (downloads only the small `.sha256` sidecar files,
  not the full archives):

      mix exclosured_precompiled.checksum

  ## Options

    * `--local` - Use local archives instead of downloading from GitHub
    * `--dir` - Directory containing local archives (default: `_build/precompiled`)
    * `--module` - Elixir module with `ExclosuredPrecompiled` config (auto-discovered if omitted)
    * `--base-url` - Override the download URL (uses module config if omitted)

  ## Output

  Generates `checksum-Elixir.MODULE.exs` in the project root.
  Include this file in your Hex package's `:files` list.
  """

  use Mix.Task

  @shortdoc "Generate checksums for precompiled WASM archives"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          module: :string,
          base_url: :string,
          local: :boolean,
          dir: :string
        ]
      )

    if opts[:local] do
      run_local(opts)
    else
      run_remote(opts)
    end
  end

  defp run_local(opts) do
    dir = opts[:dir] || "_build/precompiled"
    {caller_module, _config} = resolve_module(opts)
    checksums = collect_local_checksums(dir)
    write_and_report(checksums, caller_module)
  end

  defp run_remote(opts) do
    # Ensure project is compiled so we can discover modules
    Mix.Task.run("compile", [])

    {caller_module, config} = resolve_module(opts)
    base_url = opts[:base_url] || config.base_url
    checksums = download_sha256_files(base_url, config)
    write_and_report(checksums, caller_module)
  end

  defp resolve_module(opts) do
    case opts[:module] do
      nil ->
        case discover_precompiled_module() do
          nil ->
            Mix.raise(
              "[ExclosuredPrecompiled] No module with `use ExclosuredPrecompiled` found. " <>
                "Pass --module explicitly."
            )

          {mod, config} ->
            {mod, config}
        end

      module_str ->
        mod = Module.concat([module_str])
        Code.ensure_loaded!(mod)
        {mod, mod.__exclosured_precompiled_config__()}
    end
  end

  defp discover_precompiled_module do
    app = Mix.Project.config()[:app]

    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.find(fn mod ->
          Code.ensure_loaded?(mod) and
            function_exported?(mod, :__exclosured_precompiled_config__, 0)
        end)
        |> case do
          nil -> nil
          mod -> {mod, mod.__exclosured_precompiled_config__()}
        end

      :undefined ->
        nil
    end
  end

  defp write_and_report(checksums, caller_module) do
    path = ExclosuredPrecompiled.write_checksum_file(checksums, caller_module)

    Mix.shell().info("Checksums written to #{path}:")

    for {name, hash} <- checksums do
      Mix.shell().info("  #{name}: #{hash}")
    end
  end

  defp collect_local_checksums(dir) do
    dir
    |> Path.join("*.tar.gz")
    |> Path.wildcard()
    |> Map.new(fn archive_path ->
      sha_file = archive_path <> ".sha256"
      archive_name = Path.basename(archive_path)

      checksum =
        if File.exists?(sha_file) do
          sha_file
          |> File.read!()
          |> String.trim()
          |> String.split(~r/\s+/)
          |> hd()
          |> then(&"sha256:#{&1}")
        else
          ExclosuredPrecompiled.compute_checksum(archive_path)
        end

      {archive_name, checksum}
    end)
  end

  defp download_sha256_files(base_url, config) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "exclosured_checksums_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    checksums =
      Map.new(config.modules, fn module_name ->
        archive = ExclosuredPrecompiled.archive_name(module_name, config.version)
        sha_url = ExclosuredPrecompiled.download_url(base_url, archive <> ".sha256")
        sha_dest = Path.join(tmp_dir, archive <> ".sha256")

        Mix.shell().info("Downloading #{archive}.sha256...")

        case ExclosuredPrecompiled.download(sha_url, sha_dest) do
          :ok ->
            hex =
              sha_dest
              |> File.read!()
              |> String.trim()
              |> String.split(~r/\s+/)
              |> hd()

            {archive, "sha256:#{hex}"}

          {:error, reason} ->
            Mix.raise(
              "[ExclosuredPrecompiled] Failed to download #{archive}.sha256: #{inspect(reason)}\n" <>
                "  URL: #{sha_url}\n" <>
                "  Use --local with local archives instead."
            )
        end
      end)

    File.rm_rf!(tmp_dir)
    checksums
  end
end

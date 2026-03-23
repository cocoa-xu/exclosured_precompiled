defmodule Mix.Tasks.ExclosuredPrecompiled.Checksum do
  @moduledoc """
  Generate checksums for precompiled WASM archives.

  ## Usage

  From local archives (after running `exclosured_precompiled.precompile`):

      mix exclosured_precompiled.checksum --local --dir _build/precompiled --module MyLib.Precompiled

  From a GitHub Release (downloads only the small `.sha256` sidecar files,
  not the full archives):

      mix exclosured_precompiled.checksum --base-url https://github.com/user/repo/releases/download/v0.1.0 --module MyLib.Precompiled

  ## Options

    * `--module` (required) - The Elixir module that `use ExclosuredPrecompiled`
    * `--base-url` - Download `.sha256` files from this URL
    * `--local` - Use local archives instead of downloading
    * `--dir` - Directory containing local archives (default: `_build/precompiled`)

  ## Output

  Generates `checksum-Elixir.MyLib.Precompiled.exs` in the project root.
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

    module_str = opts[:module] || Mix.raise("--module is required")
    caller_module = Module.concat([module_str])

    checksums =
      if opts[:local] do
        dir = opts[:dir] || "_build/precompiled"
        collect_local_checksums(dir)
      else
        base_url = opts[:base_url] || Mix.raise("--base-url is required (or use --local)")
        config = caller_module.__exclosured_precompiled_config__()
        download_sha256_files(base_url, config)
      end

    path = ExclosuredPrecompiled.write_checksum_file(checksums, caller_module)

    Mix.shell().info("\nChecksums written to #{path}:")

    for {name, hash} <- checksums do
      Mix.shell().info("  #{name}: #{hash}")
    end

    Mix.shell().info("\nAdd to your mix.exs package files:")
    Mix.shell().info(~s|  files: [..., "checksum-*.exs"]|)
  end

  # Read checksums from local .sha256 sidecar files (or compute from archives)
  defp collect_local_checksums(dir) do
    dir
    |> Path.join("*.tar.gz")
    |> Path.wildcard()
    |> Map.new(fn archive_path ->
      sha_file = archive_path <> ".sha256"
      archive_name = Path.basename(archive_path)

      checksum =
        if File.exists?(sha_file) do
          # Read from sidecar file (format: "HEX  filename\n")
          sha_file
          |> File.read!()
          |> String.trim()
          |> String.split(~r/\s+/)
          |> hd()
          |> then(&"sha256:#{&1}")
        else
          # Fallback: compute from archive
          ExclosuredPrecompiled.compute_checksum(archive_path)
        end

      {archive_name, checksum}
    end)
  end

  # Download only .sha256 sidecar files from GitHub Release
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

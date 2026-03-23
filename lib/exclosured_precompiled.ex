defmodule ExclosuredPrecompiled do
  @moduledoc """
  Download precompiled WASM modules for Exclosured libraries.

  Library authors compile their Rust code to `.wasm` and `.js` files once,
  upload them to a GitHub Release, and publish checksums to Hex. Consumers
  get precompiled WASM without needing Rust, cargo, or wasm-bindgen.

  Since all Exclosured modules target `wasm32-unknown-unknown`, there is
  only **one compilation target**. No platform detection needed.

  ## Environment Variables

    * `HTTP_PROXY` or `http_proxy` - HTTP proxy configuration
    * `HTTPS_PROXY` or `https_proxy` - HTTPS proxy configuration
    * `HEX_CACERTS_PATH` - Custom CA certificates file path.
      Defaults to `CAStore.file_path/0` if CAStore is available.
    * `MIX_XDG` - If present, uses `:filename.basedir/3` with `:linux`
      for resolving the user cache directory.
    * `EXCLOSURED_PRECOMPILED_GLOBAL_CACHE_PATH` - Override the global
      cache directory. Useful for systems that cannot download at compile
      time (e.g., NixOS). Artifacts must be pre-downloaded to this path.
    * `EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL` - Set to `"1"` or `"true"`
      to force building from source for all packages, ignoring precompiled
      downloads. Equivalent to `config :exclosured_precompiled, force_build_all: true`.

  ## For library authors

  See the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for a step-by-step
  walkthrough.

      defmodule MyLibrary.Precompiled do
        use ExclosuredPrecompiled,
          otp_app: :my_library,
          base_url: "https://github.com/user/repo/releases/download/v0.1.0",
          version: "0.1.0",
          modules: [:my_processor, :my_filter]
      end

  ## For library consumers

  Just add the library to your deps. If it uses `ExclosuredPrecompiled`,
  WASM files are downloaded automatically during `mix compile`.

  To force building from source:

      config :exclosured_precompiled, force_build: true

  Or per-module:

      config :exclosured_precompiled, force_build: [:my_module]
  """

  @checksum_algo :sha256
  @cache_dir_name "exclosured_precompiled"
  @max_retries 3

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    base_url = Keyword.fetch!(opts, :base_url)
    version = Keyword.fetch!(opts, :version)
    modules = Keyword.fetch!(opts, :modules)

    quote do
      @exclosured_precompiled_config %{
        otp_app: unquote(otp_app),
        base_url: unquote(base_url),
        version: unquote(version),
        modules: unquote(modules)
      }

      def __exclosured_precompiled_config__, do: @exclosured_precompiled_config

      if ExclosuredPrecompiled.force_build?(unquote(otp_app), unquote(modules)) do
        require Logger
        Logger.info("[ExclosuredPrecompiled] Force build enabled, skipping precompiled download")
      else
        ExclosuredPrecompiled.ensure_downloaded!(
          unquote(otp_app),
          unquote(base_url),
          unquote(version),
          unquote(modules),
          __MODULE__
        )
      end
    end
  end

  # ---- Force build detection ----

  @doc """
  Check if force build is enabled for any of the given modules.

  Force build is triggered by:
    * `EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL` env var set to `"1"` or `"true"`
    * `config :exclosured_precompiled, force_build_all: true`
    * `config :exclosured_precompiled, force_build: true`
    * `config :exclosured_precompiled, force_build: [:module_name]`
  """
  def force_build?(_otp_app, modules) do
    force_env = System.get_env("EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL", "")

    cond do
      force_env in ["1", "true"] ->
        true

      Application.get_env(:exclosured_precompiled, :force_build_all, false) ->
        true

      Application.get_env(:exclosured_precompiled, :force_build) == true ->
        true

      is_list(Application.get_env(:exclosured_precompiled, :force_build, [])) ->
        force_list = Application.get_env(:exclosured_precompiled, :force_build, [])
        Enum.any?(modules, &(&1 in force_list))

      true ->
        false
    end
  end

  # ---- Download orchestration ----

  @doc """
  Download precompiled WASM modules if not already present.
  Called at compile time from the `__using__` macro.
  """
  def ensure_downloaded!(_otp_app, base_url, version, modules, caller_module) do
    output_dir = Application.get_env(:exclosured, :output_dir, "priv/static/wasm")

    for module_name <- modules do
      module_dir = Path.join(output_dir, to_string(module_name))
      bg_wasm = Path.join(module_dir, "#{module_name}_bg.wasm")
      js_file = Path.join(module_dir, "#{module_name}.js")

      unless File.exists?(bg_wasm) and File.exists?(js_file) do
        tar_name = archive_name(module_name, version)
        cached = cached_path(tar_name)

        unless File.exists?(cached) do
          url = download_url(base_url, tar_name)
          Mix.shell().info("[ExclosuredPrecompiled] Downloading #{module_name} from #{url}")
          download_with_retry!(url, cached)
        end

        verify_checksum!(cached, tar_name, caller_module)

        File.mkdir_p!(module_dir)
        extract!(cached, module_dir)
        Mix.shell().info("[ExclosuredPrecompiled] Extracted #{module_name} to #{module_dir}")
      end
    end
  end

  # ---- Naming ----

  @doc """
  Generate the archive filename for a module.

  Format: `MODULE-vVERSION-wasm32.tar.gz`

  Since all Exclosured modules compile to `wasm32-unknown-unknown`,
  there is only one archive per module per version.
  """
  def archive_name(module_name, version) do
    "#{module_name}-v#{version}-wasm32.tar.gz"
  end

  @doc """
  Build the download URL for an archive.
  """
  def download_url(base_url, archive_name) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/#{archive_name}"
  end

  # ---- Cache ----

  @doc """
  Path to the cached archive in the global cache directory.
  """
  def cached_path(archive_name) do
    Path.join([cache_dir(), archive_name])
  end

  # ---- Download ----

  @doc """
  Download a file from a URL to a local path with retry support.

  Retries up to #{@max_retries} times with exponential backoff on failure.
  Respects `HTTP_PROXY`, `HTTPS_PROXY`, and `HEX_CACERTS_PATH` environment
  variables.
  """
  def download_with_retry!(url, dest, attempt \\ 1) do
    case download(url, dest) do
      :ok ->
        :ok

      {:error, reason} when attempt < @max_retries ->
        sleep_ms = :rand.uniform(2000 * attempt)

        Mix.shell().info(
          "[ExclosuredPrecompiled] Download attempt #{attempt} failed: #{inspect(reason)}. " <>
            "Retrying in #{sleep_ms}ms..."
        )

        Process.sleep(sleep_ms)
        download_with_retry!(url, dest, attempt + 1)

      {:error, reason} ->
        File.rm(dest)

        Mix.raise("""
        [ExclosuredPrecompiled] Download failed after #{@max_retries} attempts.

        URL: #{url}
        Error: #{inspect(reason)}

        If you are behind a proxy, set HTTP_PROXY or HTTPS_PROXY.
        If you need to build from source, set:

            EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL=1 mix compile
        """)
    end
  end

  @doc """
  Download a file from a URL. Returns `:ok` or `{:error, reason}`.
  """
  def download(url, dest) do
    File.mkdir_p!(Path.dirname(dest))

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:crypto)

    configure_proxy!()

    http_options = [
      ssl:
        [
          verify: :verify_peer,
          depth: 4,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options(),
      timeout: 120_000,
      relaxed: true
    ]

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        File.write!(dest, body)
        :ok

      {:ok, {{_, status, _}, headers, _}} when status in [301, 302, 303, 307, 308] ->
        location =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
          |> elem(1)
          |> to_string()

        download(location, dest)

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, "HTTP #{status} #{reason}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- Checksum ----

  @doc """
  Verify the checksum of a downloaded archive against the checksum file.
  """
  def verify_checksum!(file_path, archive_name, caller_module) do
    checksums = load_checksums(caller_module)

    case Map.fetch(checksums, archive_name) do
      {:ok, expected} ->
        actual = compute_checksum(file_path)

        if actual != expected do
          Mix.raise("""
          [ExclosuredPrecompiled] Checksum mismatch for #{archive_name}!

          Expected: #{expected}
          Got:      #{actual}

          This could indicate a corrupted download or a tampered file.
          Delete the cached file and try again:

              rm #{file_path}
              mix deps.compile --force
          """)
        end

      :error ->
        Mix.shell().info(
          "[ExclosuredPrecompiled] Warning: no checksum found for #{archive_name}, " <>
            "skipping verification"
        )
    end
  end

  @doc """
  Compute the SHA-256 checksum of a file.

  Returns a string in the format `"sha256:HEX_HASH"`.
  """
  def compute_checksum(file_path) do
    file_path
    |> File.read!()
    |> then(&:crypto.hash(@checksum_algo, &1))
    |> Base.encode16(case: :lower)
    |> then(&"sha256:#{&1}")
  end

  @doc """
  Load checksums from the checksum file shipped with the Hex package.
  """
  def load_checksums(caller_module) do
    checksum_file = checksum_file_path(caller_module)

    if File.exists?(checksum_file) do
      {checksums, _} = Code.eval_file(checksum_file)
      checksums
    else
      %{}
    end
  end

  @doc """
  Path to the checksum file for a module.
  """
  def checksum_file_path(caller_module) do
    module_name =
      caller_module
      |> Module.split()
      |> Enum.join(".")

    "checksum-Elixir.#{module_name}.exs"
  end

  # ---- Extract ----

  @doc """
  Extract a tar.gz archive to a directory.

  Writes a `.sha256` file next to each extracted file for independent
  integrity verification.
  """
  def extract!(tar_path, dest_dir) do
    tar_path
    |> File.read!()
    |> :zlib.gunzip()
    |> then(&:erl_tar.extract({:binary, &1}, [:memory]))
    |> case do
      {:ok, files} ->
        for {name, content} <- files do
          file_path = Path.join(dest_dir, to_string(name))
          File.write!(file_path, content)

          hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
          File.write!(file_path <> ".sha256", "#{hash}  #{name}\n")
        end

      {:error, reason} ->
        Mix.raise("[ExclosuredPrecompiled] Failed to extract #{tar_path}: #{inspect(reason)}")
    end
  end

  # ---- Packaging (for library authors) ----

  @doc """
  Package a compiled WASM module into a tar.gz archive for publishing.

  Returns the path to the created archive.
  """
  def package_module(module_name, version, opts \\ []) do
    wasm_dir = Keyword.get(opts, :wasm_dir, "priv/static/wasm/#{module_name}")
    output_dir = Keyword.get(opts, :output_dir, "_build/precompiled")

    files =
      Path.wildcard(Path.join(wasm_dir, "*"))
      |> Enum.filter(&(not File.dir?(&1)))
      |> Enum.map(fn path ->
        {String.to_charlist(Path.basename(path)), File.read!(path)}
      end)

    if files == [] do
      Mix.raise("[ExclosuredPrecompiled] No files found in #{wasm_dir}. Run `mix compile` first.")
    end

    File.mkdir_p!(output_dir)
    archive = archive_name(module_name, version)
    archive_path = Path.join(output_dir, archive)

    tmp_tar = Path.join(output_dir, "tmp_#{:erlang.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(tmp_tar), files, [])
    tar_data = File.read!(tmp_tar)
    File.rm!(tmp_tar)

    File.write!(archive_path, :zlib.gzip(tar_data))

    # Write .sha256 sidecar file
    checksum = compute_checksum(archive_path)
    # Strip the "sha256:" prefix for the sidecar file (standard sha256sum format)
    "sha256:" <> hex = checksum
    File.write!(archive_path <> ".sha256", "#{hex}  #{archive}\n")

    archive_path
  end

  @doc """
  Generate checksums for all archives in a directory.

  Returns a map of `%{"filename" => "sha256:hex_hash"}`.
  """
  def generate_checksums(archive_dir) do
    archive_dir
    |> Path.join("*.tar.gz")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {Path.basename(path), compute_checksum(path)}
    end)
  end

  @doc """
  Write checksums to a file.
  """
  def write_checksum_file(checksums, caller_module) do
    path = checksum_file_path(caller_module)
    content = inspect(checksums, pretty: true, limit: :infinity)
    File.write!(path, content)
    path
  end

  # ---- Private helpers ----

  defp cache_dir do
    cond do
      path = System.get_env("EXCLOSURED_PRECOMPILED_GLOBAL_CACHE_PATH") ->
        path

      System.get_env("MIX_XDG") ->
        Path.join(
          :filename.basedir(:user_cache, @cache_dir_name, %{os: :linux}) |> to_string(),
          "precompiled_wasm"
        )

      true ->
        Path.join([user_cache_dir(), @cache_dir_name, "precompiled_wasm"])
    end
  end

  defp user_cache_dir do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join(System.get_env("HOME", "~"), "Library/Caches")

      {:unix, _} ->
        System.get_env(
          "XDG_CACHE_HOME",
          Path.join(System.get_env("HOME", "~"), ".cache")
        )

      {:win32, _} ->
        System.get_env(
          "LOCALAPPDATA",
          System.get_env("APPDATA", System.tmp_dir!())
        )
    end
  end

  defp cacerts_options do
    cond do
      path = System.get_env("HEX_CACERTS_PATH") ->
        [cacertfile: String.to_charlist(path)]

      Code.ensure_loaded?(CAStore) ->
        [cacertfile: String.to_charlist(CAStore.file_path())]

      true ->
        []
    end
  end

  defp configure_proxy! do
    # HTTP proxy
    case System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      nil ->
        :ok

      proxy ->
        uri = URI.parse(proxy)
        host = String.to_charlist(uri.host || "")
        port = uri.port || 80
        :httpc.set_options([{:proxy, {{host, port}, []}}])
    end

    # HTTPS proxy
    case System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      nil ->
        :ok

      proxy ->
        uri = URI.parse(proxy)
        host = String.to_charlist(uri.host || "")
        port = uri.port || 443
        :httpc.set_options([{:https_proxy, {{host, port}, []}}])
    end
  end
end

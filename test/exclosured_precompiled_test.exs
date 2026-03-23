defmodule ExclosuredPrecompiledTest do
  use ExUnit.Case

  @test_dir Path.join(
              System.tmp_dir!(),
              "exclosured_precompiled_test_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "archive_name/2" do
    test "generates correct filename" do
      assert ExclosuredPrecompiled.archive_name("my_mod", "0.1.0") ==
               "my_mod-v0.1.0-wasm32.tar.gz"
    end

    test "handles atom module name" do
      assert ExclosuredPrecompiled.archive_name(:my_mod, "1.2.3") ==
               "my_mod-v1.2.3-wasm32.tar.gz"
    end
  end

  describe "download_url/2" do
    test "joins base URL and archive name" do
      url =
        ExclosuredPrecompiled.download_url(
          "https://github.com/user/repo/releases/download/v0.1.0",
          "my_mod-v0.1.0-wasm32.tar.gz"
        )

      assert url ==
               "https://github.com/user/repo/releases/download/v0.1.0/my_mod-v0.1.0-wasm32.tar.gz"
    end

    test "strips trailing slash from base URL" do
      url =
        ExclosuredPrecompiled.download_url(
          "https://example.com/releases/",
          "mod-v1.0.0-wasm32.tar.gz"
        )

      assert url == "https://example.com/releases/mod-v1.0.0-wasm32.tar.gz"
    end
  end

  describe "compute_checksum/1" do
    test "computes SHA-256 checksum with prefix" do
      file = Path.join(@test_dir, "test.bin")
      File.write!(file, "hello world")

      checksum = ExclosuredPrecompiled.compute_checksum(file)
      assert String.starts_with?(checksum, "sha256:")
      # "sha256:" + 64 hex chars
      assert String.length(checksum) == 7 + 64
    end

    test "same content produces same checksum" do
      file1 = Path.join(@test_dir, "a.bin")
      file2 = Path.join(@test_dir, "b.bin")
      File.write!(file1, "identical content")
      File.write!(file2, "identical content")

      assert ExclosuredPrecompiled.compute_checksum(file1) ==
               ExclosuredPrecompiled.compute_checksum(file2)
    end

    test "different content produces different checksum" do
      file1 = Path.join(@test_dir, "a.bin")
      file2 = Path.join(@test_dir, "b.bin")
      File.write!(file1, "content A")
      File.write!(file2, "content B")

      refute ExclosuredPrecompiled.compute_checksum(file1) ==
               ExclosuredPrecompiled.compute_checksum(file2)
    end
  end

  describe "package_module/3 and extract!/2" do
    test "roundtrip: package then extract" do
      # Create fake WASM files
      wasm_dir = Path.join(@test_dir, "wasm/test_mod")
      File.mkdir_p!(wasm_dir)
      File.write!(Path.join(wasm_dir, "test_mod_bg.wasm"), <<0, 97, 115, 109>>)
      File.write!(Path.join(wasm_dir, "test_mod.js"), "export default function init() {}")

      # Package
      output_dir = Path.join(@test_dir, "output")

      archive_path =
        ExclosuredPrecompiled.package_module("test_mod", "0.1.0",
          wasm_dir: wasm_dir,
          output_dir: output_dir
        )

      assert File.exists?(archive_path)
      assert String.ends_with?(archive_path, "test_mod-v0.1.0-wasm32.tar.gz")

      # Verify .sha256 sidecar was created alongside the archive
      sha_path = archive_path <> ".sha256"
      assert File.exists?(sha_path)
      sha_content = File.read!(sha_path)
      assert sha_content =~ "test_mod-v0.1.0-wasm32.tar.gz"
      [hex | _] = String.split(String.trim(sha_content))
      assert String.length(hex) == 64

      # Verify sidecar matches computed checksum
      "sha256:" <> computed_hex = ExclosuredPrecompiled.compute_checksum(archive_path)
      assert hex == computed_hex

      # Extract to a new directory
      extract_dir = Path.join(@test_dir, "extracted")
      File.mkdir_p!(extract_dir)
      ExclosuredPrecompiled.extract!(archive_path, extract_dir)

      # Verify files were extracted
      assert File.exists?(Path.join(extract_dir, "test_mod_bg.wasm"))
      assert File.exists?(Path.join(extract_dir, "test_mod.js"))

      # Verify SHA-256 files were created
      assert File.exists?(Path.join(extract_dir, "test_mod_bg.wasm.sha256"))
      assert File.exists?(Path.join(extract_dir, "test_mod.js.sha256"))

      # Verify content matches
      assert File.read!(Path.join(extract_dir, "test_mod_bg.wasm")) == <<0, 97, 115, 109>>

      assert File.read!(Path.join(extract_dir, "test_mod.js")) ==
               "export default function init() {}"

      # Verify SHA-256 content
      sha_content = File.read!(Path.join(extract_dir, "test_mod_bg.wasm.sha256"))
      assert sha_content =~ "test_mod_bg.wasm"
      assert String.length(String.trim(sha_content)) > 64
    end
  end

  describe "generate_checksums/1" do
    test "generates checksums for all tar.gz files in directory" do
      dir = Path.join(@test_dir, "archives")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "a-v0.1.0-wasm32.tar.gz"), "archive A")
      File.write!(Path.join(dir, "b-v0.1.0-wasm32.tar.gz"), "archive B")
      File.write!(Path.join(dir, "not-an-archive.txt"), "ignore me")

      checksums = ExclosuredPrecompiled.generate_checksums(dir)

      assert map_size(checksums) == 2
      assert Map.has_key?(checksums, "a-v0.1.0-wasm32.tar.gz")
      assert Map.has_key?(checksums, "b-v0.1.0-wasm32.tar.gz")
      refute Map.has_key?(checksums, "not-an-archive.txt")

      for {_name, hash} <- checksums do
        assert String.starts_with?(hash, "sha256:")
      end
    end
  end

  describe "checksum_file_path/1" do
    test "generates path from module name" do
      assert ExclosuredPrecompiled.checksum_file_path(MyApp.Precompiled) ==
               "checksum-Elixir.MyApp.Precompiled.exs"
    end
  end

  describe "force_build_reason/3" do
    test "returns nil by default" do
      assert ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.1.0") == nil
    end

    test "returns reason for -dev version" do
      reason = ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.1.0-dev")
      assert reason =~ "pre-release"
    end

    test "returns reason for -rc version" do
      reason = ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.2.0-rc.1")
      assert reason =~ "pre-release"
    end

    test "returns nil for stable version" do
      assert ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "1.0.0") == nil
    end

    test "returns reason when env var is set to 1" do
      System.put_env("EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL", "1")
      reason = ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.1.0")
      assert reason =~ "EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL"
      System.delete_env("EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL")
    end

    test "returns reason when env var is 'true'" do
      System.put_env("EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL", "true")
      reason = ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.1.0")
      assert reason =~ "EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL"
      System.delete_env("EXCLOSURED_PRECOMPILED_FORCE_BUILD_ALL")
    end

    test "returns :internal when set by precompile task" do
      ExclosuredPrecompiled.set_force_build_all(true)
      assert ExclosuredPrecompiled.force_build_reason(:my_app, [:mod1], "0.1.0") == :internal
      ExclosuredPrecompiled.set_force_build_all(false)
    end
  end
end

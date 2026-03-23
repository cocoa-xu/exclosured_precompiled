defmodule ExclosuredPrecompiled.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :exclosured_precompiled,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :crypto]]
  end

  defp deps do
    [
      {:castore, "~> 0.1 or ~> 1.0"},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false}
    ]
  end

  defp description do
    "Download precompiled WASM modules for Exclosured libraries, " <>
      "removing the need for Rust toolchain installation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/cocoa-xu/exclosured_precompiled"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md PRECOMPILATION_GUIDE.md)
    ]
  end

  defp docs do
    [
      main: "ExclosuredPrecompiled",
      extras: ["README.md", "PRECOMPILATION_GUIDE.md", "CHANGELOG.md"]
    ]
  end
end

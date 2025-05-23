defmodule Late.MixProject do
  use Mix.Project

  def project do
    [
      app: :late,
      version: "0.3.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A websocket client using MintWebsocket",
      package: package(),
      test_coverage: [
        ignore_modules: [~r(Late.Test*)]
      ],
      source_url: "https://github.com/hkrutzer/late",
      source_ref: "master",
      docs: [
        main: "readme",
        extras: [
          "README.md": [title: "Introduction"]
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: [~c"lib", ~c"test/support"]
  defp elixirc_paths(_), do: [~c"lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.2", only: :test},
      {:castore, "~> 1.0", only: :dev},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:jason, "~> 1.2", only: :dev},
      {:mint, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:websock_adapter, "~> 0.5.5", only: :test}
    ]
  end

  defp package do
    [
      name: "late",
      files: ~w(lib .formatter.exs mix.exs README.md),
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => "https://github.com/hkrutzer/late"
      }
    ]
  end
end

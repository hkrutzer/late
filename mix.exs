defmodule Late.MixProject do
  use Mix.Project

  def project do
    [
      app: :late,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:jason, "~> 1.2", only: :dev},
      {:castore, "~> 1.0", only: :dev},
      {:mint, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:websock_adapter, "~> 0.5.5", only: :test}
    ]
  end
end

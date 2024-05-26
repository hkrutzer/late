defmodule Late.TestServer do
  @moduledoc false

  def start(port) do
    children = [
      {Bandit, plug: Late.TestRouter, scheme: :http, port: port}
    ]

    opts = [strategy: :one_for_one, name: Late.TestServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

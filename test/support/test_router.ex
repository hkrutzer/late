defmodule Late.TestRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(:dispatch)

  get "/websocket" do
    dbg(conn)
    conn = fetch_query_params(conn)

    test_pid = Base.decode64!(conn.query_params["test_pid"]) |> :erlang.binary_to_term()

    conn
    |> WebSockAdapter.upgrade(Late.WebsocketHandler, %{test_pid: test_pid}, timeout: :infinity)
    |> halt()
  end
end

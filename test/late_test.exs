defmodule LateTest do
  use ExUnit.Case
  doctest Late

  setup_all do
    Late.TestServer.start(8888)
    :ok
  end

  defmodule TestConnection do
    @behaviour Late

    require Logger

    @impl true
    def init(data) do
      dbg(data)
      {:ok, 0}
    end

    @impl true
    def handle_connect(state) do
      {:reply, {:text, "hi"}, state}
    end

    @impl true
    def handle_call({:test_call, msg}, from, state) do
      Late.reply(from, :ok_u_fool)
      {:reply, {:text, msg}, state}
    end

    @impl true
    def handle_in({:text, "bye" <> _text}, state) do
      {:stop, state}
    end

    @impl true
    def handle_info(message, state) do
      Logger.info("Handle in 2 #{inspect(message)}")
      {:reply, [{:text, "mesage one"}, {:text, message}], state}
    end
  end

  test "connects to a server and sends a message" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query("test_pid=#{client_pid}")

    {:ok, _} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    assert_receive {:server_msg, {:text, "hi"}}
  end

  test "can receive messages" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query("test_pid=#{client_pid}")

    {:ok, _} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    assert_receive {:server_msg, {:text, "hi"}}
  end

  test "handles call"

  test "can disconnect"

  test "handles normal disconnects"
end

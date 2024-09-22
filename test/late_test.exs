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

    def server_disconnect(pid, type) do
      Process.send(pid, {:disconnect, type}, [])
    end

    @impl true
    def init(init) do
      {:ok, Enum.into(init, %{})}
    end

    @impl true
    def handle_connect(state) do
      {:reply, {:text, "hi"}, state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      Process.send(state.test_pid, {:handle_disconnect, reason}, [])
      {:ok, state}
    end

    @impl true
    def handle_call({:test_call, msg}, from, state) do
      Late.reply(from, :ok)
      {:reply, {:text, msg}, state}
    end

    def handle_call(:kill_server_worker, from, state) do
      {:reply, {:text, "kill"}, state |> Map.put(:from, from)}
    end

    def handle_call(:disconnect, from, state) do
      Late.reply(from, :ok)
      {:stop, state}
    end

    @impl true
    def handle_in({:text, "Greetings!"} = msg, state) do
      Process.send(state.test_pid, {:handle_in, msg}, [])
      {:ok, state}
    end

    def handle_in({:text, "bye" <> _text}, state) do
      {:stop, state}
    end

    @impl true
    def handle_info({:disconnect, :normal_close}, state),
      do: {:reply, {:text, "normal_close"}, state}

    def handle_info({:disconnect, :error_close}, state),
      do: {:reply, {:text, "error_close"}, state}

    def handle_info(message, state) do
      Logger.info("Handle in 2 #{inspect(message)}")
      {:reply, [{:text, "message one"}, {:text, message}], state}
    end
  end

  test "connects to a server and send and receive a message" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, _} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    assert_receive {:handle_in, {:text, "Greetings!"}}
    assert_receive {:server_msg, {:text, "hi"}}
  end

  test "can receive messages" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, _} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    assert_receive {:server_msg, {:text, "hi"}}
  end

  test "can disconnect" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, pid} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    assert_receive {:server_msg, {:text, "hi"}}
    Late.call(pid, :disconnect)
    Process.sleep(20)
    refute Process.alive?(pid)
  end

  test "handles normal server-side disconnects by exiting normally" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, pid} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    TestConnection.server_disconnect(pid, :normal_close)
    assert_receive {:handle_disconnect, {1000, "Bye!"}}
    Process.sleep(20)
    refute Process.alive?(pid)
  end

  test "handles abnormal server-side disconnects by exiting with error" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url),
        debug: [:trace]
      )

    TestConnection.server_disconnect(pid, :error_close)
    assert_receive {:handle_disconnect, {1011, "Oops"}}
    assert_receive {:EXIT, ^pid, {:shutdown, {1011, "Oops"}}}
    refute Process.alive?(pid)
  end

  describe "connection failures" do
    test "does not start when attempting to connect" do
      {:error, %Mint.TransportError{reason: :econnrefused}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:25",
          debug: [:trace]
        )
    end

    test "does not start when connecting to host that offers no websocket" do
      {:error, %Mint.WebSocket.UpgradeFailureError{}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:8888/text",
          debug: [:trace]
        )
    end

    test "does not start when connection times out" do
      {:error, %Mint.TransportError{reason: :timeout}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:8888/sleep",
          connect_timeout: 100,
          debug: [:trace]
        )
    end

    test "exits when the connection is closed" do
      client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

      url =
        URI.parse("ws://localhost:8888/websocket")
        |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

      {:ok, pid} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: URI.to_string(url),
          debug: [:trace]
        )

      Process.flag(:trap_exit, true)
      {%Mint.TransportError{reason: :closed}, _} =
        catch_exit(Late.call(pid, :kill_server_worker))
    end
  end
end

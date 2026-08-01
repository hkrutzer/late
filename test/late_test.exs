defmodule LateTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  doctest Late

  defmodule TestConnection do
    @behaviour Late

    def server_disconnect(pid, type) do
      Process.send(pid, {:disconnect, type}, [])
    end

    @impl true
    def init(init) do
      {:ok, Enum.into(init, %{})}
    end

    @impl true
    def handle_connect(_headers, state) do
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
      {:reply, [{:text, "message one"}, {:text, message}], state}
    end
  end

  defmodule ConnectOnlyConnection do
    @behaviour Late

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule TestHeadersConnection do
    @behaviour Late

    @impl true
    def init(init) do
      {:ok, Enum.into(init, %{})}
    end

    @impl true
    def handle_connect(headers, state) do
      Process.send(state.test_pid, {:headers, headers}, [])
      {:stop, state}
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
        url: URI.to_string(url)
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
        url: URI.to_string(url)
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
        url: URI.to_string(url)
      )

    assert_receive {:server_msg, {:text, "hi"}}
    Late.call(pid, :disconnect)
    Process.sleep(20)
    refute Process.alive?(pid)
  end

  test "sends a close frame when the connection process terminates" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, pid} =
      Late.start_link(
        TestConnection,
        [test_pid: self()],
        url: URI.to_string(url)
      )

    assert_receive {:server_msg, {:text, "hi"}}
    :ok = :gen_statem.stop(pid)
    assert_receive {:server_terminate, :remote}
  end

  test "can read headers" do
    client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

    url =
      URI.parse("ws://localhost:8888/websocket")
      |> URI.append_query(URI.encode_query(%{test_pid: client_pid}))

    {:ok, _pid} =
      Late.start_link(
        TestHeadersConnection,
        [test_pid: self()],
        url: URI.to_string(url)
      )

    assert_receive {:headers, headers}
    headers = Enum.into(headers, %{})
    assert headers["x-test-header"] == "123"
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
        url: URI.to_string(url)
      )

    TestConnection.server_disconnect(pid, :normal_close)
    assert_receive {:handle_disconnect, {:close, 1000, "Bye!"}}
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
        url: URI.to_string(url)
      )

    TestConnection.server_disconnect(pid, :error_close)
    assert_receive {:handle_disconnect, {:close, 1011, "Oops"}}
    assert_receive {:EXIT, ^pid, {:shutdown, {1011, "Oops"}}}
    refute Process.alive?(pid)
  end

  describe "connection failures" do
    test "does not start when attempting to connect" do
      {:error, %Mint.TransportError{reason: :econnrefused}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:25"
        )
    end

    test "does not start when connecting to host that offers no websocket" do
      {:error, %Mint.WebSocket.UpgradeFailureError{}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:8888/text"
        )
    end

    test "does not start when connection times out" do
      {:error, %Mint.TransportError{reason: :timeout}} =
        Late.start_link(
          TestConnection,
          [test_pid: self()],
          url: "ws://localhost:8888/sleep",
          connect_timeout: 100
        )
    end

    test "connects when the upgrade response is split across TCP messages" do
      {server, port} = start_split_upgrade_server()
      on_exit(fn -> send(server, :stop) end)

      assert {:ok, pid} =
               Late.start_link(
                 ConnectOnlyConnection,
                 [],
                 url: "ws://localhost:#{port}/websocket"
               )

      :ok = :gen_statem.stop(pid)
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
          url: URI.to_string(url)
        )

      Process.flag(:trap_exit, true)

      capture_log(fn ->
        {%Mint.TransportError{reason: :closed}, _} =
          catch_exit(Late.call(pid, :kill_server_worker))
      end)
    end

    test "exits with the send error when a callback cannot send its reply" do
      client_pid = :erlang.term_to_binary(self()) |> Base.encode64()

      url =
        URI.parse("ws://localhost:8888/websocket")
        |> URI.append_query(URI.encode_query(%{test_pid: client_pid, send_ping: false}))

      Process.flag(:trap_exit, true)

      capture_log(fn ->
        {:ok, pid} =
          Late.start_link(
            TestConnection,
            [test_pid: self()],
            url: URI.to_string(url)
          )

        assert_receive {:server_msg, {:text, "hi"}}

        state = get_connection_state(pid)
        {:ok, closed_conn} = Mint.HTTP.close(state.conn)

        replace_connection_state(pid, fn state ->
          %{state | conn: closed_conn}
        end)

        send(pid, :trigger_send)

        assert_receive {:EXIT, ^pid, %Mint.TransportError{reason: :closed}}
      end)
    end
  end

  defp get_connection_state(pid) do
    case :sys.get_state(pid) do
      {:connected, state} -> state
      state -> state
    end
  end

  defp replace_connection_state(pid, fun) do
    :sys.replace_state(pid, fn
      {:connected, state} -> {:connected, fun.(state)}
      state -> fun.(state)
    end)
  end

  defp start_split_upgrade_server do
    test_pid = self()

    server =
      spawn(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

        {:ok, {_address, port}} = :inet.sockname(listen_socket)
        send(test_pid, {:split_upgrade_server, self(), port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)
        :ok = :gen_tcp.close(listen_socket)
        {:ok, request} = recv_http_request(socket, "")

        websocket_key = websocket_key(request)

        websocket_accept =
          :crypto.hash(:sha, websocket_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
          |> Base.encode64()

        :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
        Process.sleep(100)

        _ =
          :gen_tcp.send(socket, [
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Accept: ",
            websocket_accept,
            "\r\n\r\n"
          ])

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    receive do
      {:split_upgrade_server, ^server, port} -> {server, port}
    end
  end

  defp recv_http_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> recv_http_request(socket, acc <> data)
        error -> error
      end
    end
  end

  defp websocket_key(request) do
    Enum.find_value(String.split(request, "\r\n"), fn header ->
      case String.split(header, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "sec-websocket-key", do: String.trim(value)

        _other ->
          nil
      end
    end)
  end
end

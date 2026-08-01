defmodule Late do
  @moduledoc ~S"""
  A WebSocket client built on Mint and `:gen_statem`.

  A connection module implements the `Late` behaviour and keeps its own
  callback state:

      defmodule MyConnection do
        @behaviour Late

        @impl true
        def init(_args), do: {:ok, %{messages: []}}

        @impl true
        def handle_connect(_headers, state) do
          {:reply, {:text, "hello"}, state}
        end

        @impl true
        def handle_call({:send, message}, from, state) do
          Late.reply(from, :ok)
          {:reply, {:text, message}, state}
        end

        @impl true
        def handle_in({:text, text}, state) do
          {:ok, %{state | messages: [text | state.messages]}}
        end
      end

      {:ok, pid} =
        Late.start_link(MyConnection, [], url: "ws://localhost:3000/websocket")

      :ok = Late.call(pid, {:send, "message"})

  Callback replies of the form `{:reply, frame_or_frames, state}` send
  WebSocket frames. Calls must be answered explicitly with `reply/2`.
  """
  @behaviour :gen_statem

  require Mint.HTTP
  require Logger

  @doc false
  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :resp_headers,
    :state
  ]

  ## Public API
  @type state :: term

  @type frame :: Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()

  @type call_result ::
          {:ok, state}
          | {:reply, frame | [frame], state}
          | {:stop, state}
          | {:stop, reason :: term(), state}

  @type disconnect_reason ::
          {:close, code :: non_neg_integer() | nil, reason :: binary() | nil}
          | Mint.TransportError.t()

  @doc """
  Initializes the connection module's callback state before connecting.
  """
  @callback init(term) :: {:ok, state}

  @doc """
  Invoked with the upgrade response headers after connecting or reconnecting.
  """
  @callback handle_connect(Mint.Types.headers(), state) :: call_result

  @doc """
  Invoked after disconnecting.

  A server close frame is reported as `{:close, code, reason}`. Transport
  failures are reported as `Mint.TransportError` structs.
  """
  @callback handle_disconnect(disconnect_reason, state) :: {:ok, state}

  @doc """
  Invoked when the server receives a call message sent by `Late.call/3`.

  You must reply to the calling process using `Late.reply/2`.
  Returning a `{:reply, [frame], state}` tuple will send the frames to the WebSocket server,
  not the calling process.
  """
  @callback handle_call(term, {pid, term}, state) :: call_result

  @doc """
  Invoked when the server receives a WebSocket frame.
  """
  @callback handle_in(frame, state) :: call_result

  @doc """
  Invoked when the server receives any message that is not a call or WebSocket frame.
  """
  @callback handle_info(any(), state) :: call_result
  @optional_callbacks handle_call: 3,
                      handle_disconnect: 2,
                      handle_info: 2,
                      handle_connect: 2,
                      handle_in: 2

  @doc """
  Replies to the given `Late.call/3` caller.

  Wrapper for `:gen_statem.reply/2`.
  """
  def reply(from, reply) do
    :gen_statem.reply(from, reply)
  end

  @doc """
  Calls the given server.

  Wrapper for `:gen_statem.call/3`.
  """
  def call(server, message, timeout \\ 5000) do
    :gen_statem.call(server, message, timeout)
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, opts}}
  end

  @doc """
  Starts a linked WebSocket connection using `module` as its callback module.

  The callback module is initialized with `args` before the connection is
  opened.

  ## Options

    * `:url` - required WebSocket URL using the `ws` or `wss` scheme
    * `:headers` - request headers sent during the WebSocket upgrade
    * `:connect_timeout` - timeout in milliseconds for connecting and receiving
      the upgrade response; defaults to `1000`
    * `:mint_opts` - options passed to `Mint.HTTP1.connect/4`
    * `:websocket_opts` - options passed to `Mint.WebSocket.upgrade/5`
    * `:name` - a local atom, `{:global, term}`, or `{:via, module, term}` name
    * `:hibernate_after`, `:debug`, and `:spawn_opt` - options passed to
      `:gen_statem.start_link/4`
  """
  def start_link(module, args, opts) do
    {gen_statem_opts, opts} = Keyword.split(opts, [:hibernate_after, :debug, :spawn_opt])
    start_args = {module, args, opts}

    case Keyword.fetch(opts, :name) do
      :error ->
        :gen_statem.start_link(__MODULE__, start_args, gen_statem_opts)

      {:ok, atom} when is_atom(atom) ->
        :gen_statem.start_link({:local, atom}, __MODULE__, start_args, gen_statem_opts)

      {:ok, {:global, _term} = tuple} ->
        :gen_statem.start_link(tuple, __MODULE__, start_args, gen_statem_opts)

      {:ok, {:via, via_module, _term} = tuple} when is_atom(via_module) ->
        :gen_statem.start_link(tuple, __MODULE__, start_args, gen_statem_opts)

      {:ok, other} ->
        raise ArgumentError, """
        expected :name option to be one of the following:
          * nil
          * atom
          * {:global, term}
          * {:via, module, term}
        Got: #{inspect(other)}
        """
    end
  end

  ## Callbacks

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @doc false
  @impl :gen_statem
  def terminate(_reason, _state_name, %__MODULE__{conn: nil}), do: :ok

  def terminate(_reason, _state_name, %__MODULE__{} = state) do
    if Mint.HTTP.open?(state.conn) do
      state =
        case send_frame(state, :close) do
          {:ok, state} -> state
          {:error, state, _reason} -> state
        end

      _ = Mint.HTTP.close(state.conn)
    end

    :ok
  end

  ## Init callbacks

  @doc false
  @impl :gen_statem
  def init({mod, args, opts}) do
    case mod.init(args) do
      {:ok, mod_state} ->
        connect_timeout = Keyword.get(opts, :connect_timeout, 1000)

        mint_opts = Keyword.get(opts, :mint_opts, [])
        mint_opts = Keyword.put(mint_opts, :mode, :passive)

        mint_opts =
          Keyword.update(
            mint_opts,
            :transport_opts,
            [timeout: connect_timeout],
            fn transport_opts ->
              Keyword.put_new(transport_opts, :timeout, connect_timeout)
            end
          )

        mint_websocket_opts = Keyword.get(opts, :websocket_opts, [])
        uri = URI.parse(Keyword.get(opts, :url))
        headers = Keyword.get(opts, :headers, [])

        {http_scheme, ws_scheme} =
          case uri.scheme do
            "ws" -> {:http, :ws}
            "wss" -> {:https, :wss}
          end

        uri =
          case uri.path do
            nil -> Map.put(uri, :path, "/")
            _ -> uri
          end

        path =
          case uri.query do
            nil -> uri.path
            query -> uri.path <> "?" <> query
          end

        # `connect_timeout` is a budget for the whole handshake, so the deadline
        # starts before connecting rather than being restarted per step.
        deadline = System.monotonic_time(:millisecond) + connect_timeout

        # TODO Make HTTP1 configurable
        with {:ok, conn} <- Mint.HTTP1.connect(http_scheme, uri.host, uri.port, mint_opts),
             {:ok, conn, ref} <-
               Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, mint_websocket_opts),
             {:ok, conn, status, resp_headers, rest} <-
               recv_upgrade_response(conn, ref, deadline),
             {:ok, conn} <- Mint.HTTP.set_mode(conn, :active),
             {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, resp_headers),
             # In some cases the data from recv might already contain
             # the initial frames, so we decode those.
             # To similate this happening, add a delay after Mint.WebSocket.upgrade
             {:ok, websocket, initial_data} <- maybe_decode_initial_data(websocket, rest) do
          initial_frames =
            Enum.map(initial_data, &{:next_event, :internal, {:handle_frame, &1}})

          state = %__MODULE__{
            conn: conn,
            websocket: websocket,
            resp_headers: resp_headers,
            request_ref: ref,
            state: {mod, mod_state}
          }

          {:ok, :connected, state,
           [{:next_event, :internal, :maybe_handle_connect}] ++ initial_frames}
        else
          {:error, reason} ->
            {:error, reason}

          {:error, conn, reason, _response} ->
            # Mint.HTTP.recv error
            Mint.HTTP.close(conn)
            {:error, reason}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, reason}
        end
    end
  end

  # The upgrade response can be split over several TCP packets, so keep
  # receiving until Mint has parsed both the status and the headers. Mint emits
  # the 101's `:headers` and `:done` in the same pass, so once those are in
  # hand the remaining responses are the complete rest of the response.
  defp recv_upgrade_response(conn, ref, deadline) do
    recv_until_response(conn, ref, deadline, [])
  end

  defp recv_until_response(conn, ref, _deadline, [
         {:status, ref, status},
         {:headers, ref, resp_headers} | rest
       ]) do
    {:ok, conn, status, resp_headers, rest}
  end

  defp recv_until_response(conn, ref, deadline, responses) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:ok, conn, more} <- Mint.HTTP.recv(conn, 0, timeout) do
      recv_until_response(conn, ref, deadline, responses ++ more)
    end
  end

  defp maybe_decode_initial_data(websocket, [{:done, _ref}]), do: {:ok, websocket, []}

  defp maybe_decode_initial_data(websocket, [{:data, ref, data}, {:done, ref}]) do
    Mint.WebSocket.decode(websocket, data)
  end

  ## State functions
  @doc false
  def connected(:info, message, state)
      when Mint.HTTP.is_connection_message(state.conn, message) do
    ref = state.request_ref

    with {:ok, conn, [{:data, ^ref, data}]} <- Mint.WebSocket.stream(state.conn, message),
         {:ok, websocket, frames} <- Mint.WebSocket.decode(state.websocket, data) do
      # Send each frame as a new action
      actions = Enum.map(frames, &{:next_event, :internal, {:handle_frame, &1}})
      {:keep_state, %{state | conn: conn, websocket: websocket}, actions}
    else
      # Handle decode errors
      {:error, websocket, reason} ->
        {:stop, reason, %{state | websocket: websocket}}

      # Handle stream errors
      {:error, conn, %Mint.TransportError{reason: :closed} = reason, _responses} ->
        {mod, mod_state} = state.state
        state = %{state | conn: conn}

        # TODO Add reconnect
        if function_exported?(mod, :handle_disconnect, 2) do
          case apply(mod, :handle_disconnect, [reason, mod_state]) do
            {:ok, mod_state} ->
              state = %{state | state: {mod, mod_state}}
              {:stop, reason, state}
          end
        else
          {:stop, reason, state}
        end

      {:error, conn, reason, _responses} ->
        {:stop, reason, %{state | conn: conn}}

      :unknown ->
        :keep_state_and_data
    end
  end

  def connected(:info, msg, %{state: {mod, mod_state}} = state) do
    maybe_handle(mod, :handle_info, [msg, mod_state], state)
  end

  def connected(:internal, :maybe_handle_connect, %{state: {mod, mod_state}} = state) do
    maybe_handle(mod, :handle_connect, [state.resp_headers, mod_state], state)
  end

  def connected(:internal, {:handle_frame, {:ping, data}}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> {:keep_state, state}
      {:error, state, reason} -> {:stop, reason, state}
    end
  end

  def connected(:internal, {:handle_frame, {:pong, _data}}, state) do
    {:keep_state, state}
  end

  def connected(:internal, {:handle_frame, {op, text}}, state) when op in [:text, :binary] do
    {mod, mod_state} = state.state
    maybe_handle(mod, :handle_in, [{op, text}, mod_state], state)
  end

  def connected(:internal, {:handle_frame, {:close, code, reason}}, state) do
    {:keep_state, state, {:next_event, :internal, {:disconnect, code, reason}}}
  end

  def connected(:internal, {:handle_frame, frame}, _state) do
    Logger.error("Received unknown websocket frame #{inspect(frame)}")
    :keep_state_and_data
  end

  def connected(:internal, {:disconnect, code, reason}, %{state: {mod, mod_state}} = state) do
    stop_reason = if code == 1000, do: :normal, else: {:shutdown, {code, reason}}

    state =
      case send_frame(state, {:close, code, reason}) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end

    {:ok, conn} = Mint.HTTP.close(state.conn)
    state = %{state | conn: conn}

    if function_exported?(mod, :handle_disconnect, 2) do
      case apply(mod, :handle_disconnect, [{:close, code, reason}, mod_state]) do
        # TODO Add reconnect
        {:ok, mod_state} ->
          state = %{state | state: {mod, mod_state}}
          {:stop, stop_reason, state}
      end
    else
      {:stop, stop_reason, state}
    end
  end

  def connected({:call, from}, msg, %{state: {mod, mod_state}} = state) do
    # In Postgrex there is a hack here:
    # https://github.com/elixir-ecto/postgrex/blob/cb6bdbcbbb03edd78bd396f922f23abcd77bb393/lib/postgrex/simple_connection.ex#L370-L377
    # I could not replicate what it solved and it should no longer be needed in OTP 26:
    # https://github.com/erlang/otp/pull/7081
    handle(mod, :handle_call, [msg, from, mod_state], from, state)
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = put_in(state.websocket, websocket),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, put_in(state.conn, conn)}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, put_in(state.websocket, websocket), reason}

      {:error, conn, reason} ->
        {:error, put_in(state.conn, conn), reason}
    end
  end

  defp send_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case send_frame(state, frame) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, state, reason} -> {:halt, {:error, state, reason}}
      end
    end)
  end

  ## Helpers

  defp maybe_handle(mod, fun, args, state) do
    if function_exported?(mod, fun, length(args)) do
      handle(mod, fun, args, nil, state)
    else
      :keep_state_and_data
    end
  end

  defp handle(mod, fun, args, _from, state) do
    case apply(mod, fun, args) do
      {:ok, mod_state} ->
        {:keep_state, %{state | state: {mod, mod_state}}}

      {:reply, reply, mod_state} ->
        state = %{state | state: {mod, mod_state}}

        case send_frames(state, List.wrap(reply)) do
          {:ok, state} -> {:keep_state, state}
          {:error, state, reason} -> {:stop, reason, state}
        end

      {:stop, mod_state} ->
        {:stop, :normal, %{state | state: {mod, mod_state}}}

      {:stop, reason, mod_state} ->
        {:stop, reason, %{state | state: {mod, mod_state}}}
    end
  end
end

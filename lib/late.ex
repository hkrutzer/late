defmodule Late do
  @moduledoc ~S"""

  ## Example

      defmodule MyConnection do
        @behaviour Late

        @impl true
        def init(_args) do
          {:ok, %{from: nil}}
        end

        @impl true
        def handle_call({:something, query}, from, state) do
          {:noreply, stuff}
        end

        @impl true
        def handle_in({:text, text}, state) do
          {:reply, [frame], new_state}
        end
      end
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
    :connect_buffer,
    :state
  ]

  ## Public API
  @type state :: term

  @type frame :: Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()

  @type call_result ::
          {:ok, state}
          | {:reply, [frame], state}
          | {:stop, any(), state}

  @type disconnect_reason ::
          {:close, code :: non_neg_integer() | nil, reason :: binary() | nil}

  @doc """

  """
  @callback init(term) :: {:ok, state}

  @doc """
  Invoked after connecting or reconnecting.
  """
  @callback handle_connect(state) :: call_result

  # @doc """
  # Invoked after disconnecting.
  # """
  @callback handle_disconnect(disconnect_reason, state) :: {:ok, state}

  @callback handle_in(frame, state) :: call_result

  @callback handle_call(term, {pid, term}, state) :: call_result

  @callback handle_info(any(), state) :: call_result

  @optional_callbacks handle_call: 3,
                      handle_disconnect: 2,
                      handle_info: 2,
                      handle_connect: 1,
                      handle_in: 2

  @doc """
  Replies to the given client.

  Wrapper for `:gen_statem.reply/2`.
  """
  # def reply({caller_pid, from} = _from, reply) when is_pid(caller_pid) do
  def reply(from, reply) do
    :gen_statem.reply(from, reply)
  end

  @doc """
  Calls the given server.

  Wrapper for `:gen_statem.call/3`.
  """
  def call(server, message, timeout \\ 5000) do
    with {__MODULE__, reason} <- :gen_statem.call(server, message, timeout) do
      exit({reason, {__MODULE__, :call, [server, message, timeout]}})
    end
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, opts}}
  end

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

  ## Init callbacks

  @doc false
  @impl :gen_statem
  def init({mod, args, opts}) do
    case mod.init(args) do
      {:ok, mod_state} ->
        mint_opts = Keyword.get(opts, :mint_opts, [])
        mint_websocket_opts = Keyword.get(opts, :mint_opts, [])
        uri = URI.parse(Keyword.get(opts, :url))
        headers = Keyword.get(opts, :headers, [])
        connect_timeout = Keyword.get(opts, :connect_timeout, 5000)

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

        # TODO Make HTTP1 configurable
        with {:ok, conn} <- Mint.HTTP1.connect(http_scheme, uri.host, uri.port, mint_opts),
             {:ok, conn, ref} <-
               Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, mint_websocket_opts) do
          state = %__MODULE__{
            request_ref: ref,
            conn: conn,
            state: {mod, mod_state}
          }

          {:ok, :connecting, state, {{:timeout, :connect_timeout}, connect_timeout, nil}}
        else
          # TODO go to disconnect state instead (allowing the callback)
          {:error, reason} ->
            {:stop, reason}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:stop, reason}
        end
    end
  end

  # def terminate(reason, _state, _data)
  # @impl true
  # def terminate(reason, state, data) do
  #   Logger.info("Terminating goodbye #{inspect(reason)} #{inspect(state)} #{inspect(data)}")
  # end

  ## State functions
  def connecting({:timeout, :connect_timeout}, _from, state) do
    Logger.debug("Connection time out")
    Mint.HTTP.close(state.conn)
    {:stop, :connect_timeout, state}
  end

  def connecting(:info, message, %{conn: conn} = state)
      when Mint.HTTP.is_connection_message(state.conn, message) do
    ref = state.request_ref

    {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers} | rest]} =
      Mint.WebSocket.stream(conn, message)

    buffer =
      case rest do
        [{:data, ^ref, data}, {:done, ^ref}] -> data
        [{:done, ^ref}] -> nil
      end

    case Mint.WebSocket.new(conn, ref, status, resp_headers) do
      {:ok, conn, websocket} ->
        state = %{
          state
          | conn: conn,
            websocket: websocket,
            resp_headers: resp_headers,
            connect_buffer: buffer
        }

        {:next_state, :connected, state,
         [
           # Clear connection timeout first, then trigger event to call handle_connect
           {{:timeout, :connect_timeout}, :cancel},
           {:next_event, :internal, :maybe_handle_connect}
         ]}

      {:error, conn, reason} ->
        {:stop, reason, %{state | conn: conn}}
    end
  end

  def connecting(:info, _message, _state), do: {:keep_state_and_data, :postpone}
  def connecting({:call, _from}, _msg, _state), do: {:keep_state_and_data, :postpone}

  def maybe_prepend_buffer(%__MODULE__{connect_buffer: nil} = state, data), do: {:ok, state, data}

  def maybe_prepend_buffer(%__MODULE__{connect_buffer: buffer} = state, data) do
    {:ok, %{state | connect_buffer: nil}, buffer <> data}
  end

  def connected(:info, message, state)
      when Mint.HTTP.is_connection_message(state.conn, message) do
    ref = state.request_ref

    with {:ok, conn, [{:data, ^ref, data}]} <- Mint.WebSocket.stream(state.conn, message),
         {:ok, state, data} <- maybe_prepend_buffer(state, data),
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
        # TODO handle_disconnect
        Logger.warning("Connection closed #{inspect(reason)}")
        {:stop, reason, %{state | conn: conn}}

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
    maybe_handle(mod, :handle_connect, [mod_state], state)
  end

  def connected(:internal, {:handle_frame, {:ping, data}}, state) do
    {:ok, state} = send_frame(state, {:pong, data})
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
    Logger.error("Received unknown websocket frame #{frame}")
    :keep_state_and_data
  end

  def connected(:internal, {:disconnect, code, reason}, %{state: {mod, mod_state}} = state) do
    if function_exported?(mod, :handle_disconnect, 2) do
      case apply(mod, :handle_disconnect, [{code, reason}, mod_state]) do
        # TODO Add reconnect
        {:ok, mod_state} ->
          state = %{state | state: {mod, mod_state}}
          Mint.HTTP.close(state.conn)
          {:stop, reason, state}
      end
    else
      Mint.HTTP.close(state.conn)
      {:stop, reason, state}
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
    Logger.debug("Sending #{inspect(frame)}")

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
        {:ok, state} = send_frames(state, List.wrap(reply))
        {:keep_state, %{state | state: {mod, mod_state}}}

      {:stop, mod_state} ->
        _ = send_frame(state, :close)
        Mint.HTTP.close(state.conn)
        {:stop, :normal, %{state | state: {mod, mod_state}}}
    end
  end
end

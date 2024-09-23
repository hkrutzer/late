# Late

Late is a websocket client library for Elixir using Mint and `:gen_statem`.

It features asynchronous and synchronous calls, checking for connection errors during process init, and a simple API.

## Usage

```elixir
defmodule TestConnection do
  @behaviour Late

  require Logger

  def send_sync(pid, message) do
    Late.call(pid, {:send, message})
  end

  def send_async(pid, message) do
    Process.send(pid, message, [])
  end

  @impl true
  def init(_opts) do
    {:ok, 0}
  end

  @impl true
  def handle_connect(state) do
    Logger.info("Connected")
    {:reply, {:text, "hi"}, state}
  end

  @impl true
  def handle_disconnect(state, reason) do
    Logger.info("Disconnected! #{inspect reason}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send, msg}, from, state) do
    Late.reply(from, :ok)
    {:reply, {:text, msg}, state}
  end

  @impl true
  def handle_in({:text, "bye"}, state) do
    {:stop, state}
  end

  def handle_in({:text, msg}, state) do
    Logger.info("Received message #{inspect msg}")
    {:ok, state}
  end

  @impl true
  def handle_info(message, state) do
    {:reply, [{:text, "mesage one"}, {:text, message}], state}
  end
end

{:ok, pid} = Late.start_link(
  TestConnection,
  [],
  url: "ws://localhost:3000/websocket"
)

:ok = TestConnection.send_sync(pid, "hello")
:ok = TestConnection.send_async(pid, "Send this message asynchronously")
```

## Installation

```elixir
def deps do
  [
    {:late, "~> 0.2.0"}
  ]
end
```


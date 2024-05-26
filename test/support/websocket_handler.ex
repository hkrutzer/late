defmodule Late.WebsocketHandler do
  @moduledoc false

  def init(data) do
    {:ok, data}
  end

  def handle_control({message, [opcode: opcode]}, state) do
    {:push, [{opcode, message}], state}
  end

  def handle_in({"close it!", [opcode: :text]}, state) do
    {:stop, :normal, {1013, "yessir"}, state}
  end

  def handle_in({message, [opcode: opcode]}, state) do
    send(state.test_pid, {:server_msg, {opcode, message}})
    # {:push, [{opcode, message}], state}
    {:ok, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  def terminate(_reason, state) do
    {:ok, state}
  end
end

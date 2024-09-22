defmodule Late.WebsocketHandler do
  @moduledoc false

  def init(data) do
    {:ok, data}
  end

  def handle_control({message, [opcode: opcode]}, state) do
    {:push, [{opcode, message}], state}
  end

  def handle_in({"normal_close", [opcode: :text]}, state) do
    {:stop, :normal, {1000, "Bye!"}, state}
  end

  def handle_in({"error_close", [opcode: :text]}, state) do
    {:stop, :normal, {1011, "Oops"}, state}
  end

  def handle_in({message, [opcode: opcode]}, state) do
    send(state.test_pid, {:server_msg, {opcode, message}})
    {:ok, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  def terminate(_reason, state) do
    {:ok, state}
  end
end

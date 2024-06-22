defmodule SpeechmaticsConnection do
  @behaviour Late

  require Logger

  @impl true
  def init(data) do
    dbg(data)
    {:ok, %{}}
  end

  @impl true
  def handle_connect(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:start, from, state) do
    {:reply,
     {:text,
      Jason.encode!(%{
        message: "StartRecognition",
        audio_format: %{
          type: "raw",
          encoding: "pcm_s16le",
          sample_rate: 16000
        },
        transcription_config: %{
          language: "nl",
          operating_point: "enhanced",
          enable_entities: true,
          enable_partials: false
        }
      })}, %{handshake_from: from}}
  end

  @impl true
  def handle_in({:text, msg}, state) do
    msg = Jason.decode!(msg)

    case msg["message"] do
      "RecognitionStarted" ->
        Late.reply(state.handshake_from, :ok)
        Logger.info("RecognitionStarted")
        {:ok, %{last_seq_no: 0}}

      "EndOfTranscript" ->
        Logger.info("EndOfTranscript event, disconnecting")
        Late.reply(state.reply_to, :ok)
        {:stop, state}

      _ ->
        Logger.info(inspect(msg, pretty: true))
        {:ok, state}
    end

  end

  def handle_call({:send, audio}, from, state) do
    Late.reply(from, :ok)
    {:reply, {:binary, audio}, %{last_seq_no: state.last_seq_no + 1}}
  end

  def handle_call(:end, from, state) do
    Logger.info("Ending!")
    state = Map.put(state, :reply_to, from)
    {:reply, {:text, Jason.encode!(%{message: "EndOfStream", last_seq_no: state.last_seq_no})}, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.info("Handle in 2 #{inspect(message)}")
    {:reply, [{:text, "mesage one"}, {:text, message}], state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    Logger.info("Disconnected!")
    {:ok, state}
  end
end

defmodule PacketSplitter do
  @moduledoc """
  Splits packets into packets of a certain byte size.
  """

  @spec split_packet(number, [binary()]) :: [binary()]
  def split_packet(size, packet) when byte_size(packet) > size do
    {chunk, rest} = :erlang.split_binary(packet, size)
    [chunk | split_packet(size, rest)]
  end

  def split_packet(_size, <<>>) do
    []
  end

  def split_packet(_size, packet) do
    [packet]
  end
end

api_key = "YOUR_API_KEY_HERE"

url =
  URI.parse("wss://eu2.rt.speechmatics.com/v2")

{:ok, pid} =
  Late.start_link(
    SpeechmaticsConnection,
    [],
    headers: [{"Authorization", "Bearer #{api_key}"}],
    url: URI.to_string(url),
    debug: []
  )

:ok = Late.call(pid, :start)

audio = File.read!("audio.wav")
for chunk <- PacketSplitter.split_packet(4000, audio) do
  Late.call(pid, {:send, chunk})
end

:ok = Late.call(pid, :end) |> dbg()

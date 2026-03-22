defmodule Traitee.Media.Pipeline do
  @moduledoc "Media processing pipeline for images, audio, and documents."

  alias Traitee.Media.TextExtractor

  @max_file_size 10 * 1024 * 1024

  @image_exts ~w(.jpg .jpeg .png .gif .webp .bmp .tiff)
  @audio_exts ~w(.mp3 .wav .ogg .m4a .flac .aac)
  @video_exts ~w(.mp4 .webm .mkv .avi .mov)
  @document_exts ~w(.txt .md .html .htm .json .csv .xml .pdf .log)

  defmodule Result do
    @moduledoc false
    defstruct [:type, :content, :metadata]

    @type t :: %__MODULE__{
            type: :image | :audio | :document | :video,
            content: String.t(),
            metadata: map()
          }
  end

  @spec process(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def process(path, opts \\ []) do
    max_size = Keyword.get(opts, :max_file_size, @max_file_size)

    with :ok <- validate_file(path, max_size),
         {:ok, type} <- detect_type(path) do
      process_by_type(type, path, opts)
    end
  end

  @spec detect_type(String.t()) ::
          {:ok, :image | :audio | :document | :video} | {:error, :unknown_type}
  def detect_type(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in @image_exts -> {:ok, :image}
      ext in @audio_exts -> {:ok, :audio}
      ext in @video_exts -> {:ok, :video}
      ext in @document_exts -> {:ok, :document}
      true -> {:error, :unknown_type}
    end
  end

  @spec extract_text(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_text(path), do: TextExtractor.extract(path)

  @spec summarize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(text, opts \\ []) do
    max_len = Keyword.get(opts, :max_length, 500)

    case Traitee.LLM.Router.complete(%{
           messages: [
             %{
               role: "user",
               content:
                 "Summarize the following content in #{max_len} characters or less:\n\n#{text}"
             }
           ]
         }) do
      {:ok, resp} -> {:ok, resp.content}
      error -> error
    end
  end

  @spec transcribe(String.t()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path) do
    if Traitee.LLM.OpenAI.configured?() do
      transcribe_whisper(path)
    else
      {:error, :no_transcription_provider}
    end
  end

  # -- Private --

  defp validate_file(path, max_size) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > max_size ->
        {:error, {:file_too_large, size, max_size}}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:file_not_found, reason}}
    end
  end

  defp process_by_type(:image, path, _opts) do
    metadata = extract_image_metadata(path)

    {:ok,
     %Result{
       type: :image,
       content: "[Image: #{Path.basename(path)}]",
       metadata: metadata
     }}
  end

  defp process_by_type(:audio, path, _opts) do
    case transcribe(path) do
      {:ok, text} ->
        {:ok,
         %Result{
           type: :audio,
           content: text,
           metadata: %{filename: Path.basename(path), transcribed: true}
         }}

      {:error, _} ->
        {:ok,
         %Result{
           type: :audio,
           content: "[Audio: #{Path.basename(path)}]",
           metadata: %{filename: Path.basename(path), transcribed: false}
         }}
    end
  end

  defp process_by_type(:document, path, _opts) do
    case TextExtractor.extract(path) do
      {:ok, text} ->
        {:ok,
         %Result{
           type: :document,
           content: text,
           metadata: %{filename: Path.basename(path), chars: String.length(text)}
         }}

      error ->
        error
    end
  end

  defp process_by_type(:video, path, _opts) do
    {:ok,
     %Result{
       type: :video,
       content: "[Video: #{Path.basename(path)}]",
       metadata: %{filename: Path.basename(path)}
     }}
  end

  defp extract_image_metadata(path) do
    stat =
      case File.stat(path) do
        {:ok, s} -> %{size: s.size}
        _ -> %{}
      end

    Map.merge(%{filename: Path.basename(path), ext: Path.extname(path)}, stat)
  end

  defp transcribe_whisper(path) do
    api_key =
      Traitee.Config.get([:channels, :whatsapp, :token]) ||
        System.get_env("OPENAI_API_KEY")

    unless api_key do
      {:error, :no_api_key}
    else
      url = "https://api.openai.com/v1/audio/transcriptions"

      boundary = "traitee-#{:erlang.unique_integer([:positive])}"
      file_data = File.read!(path)
      filename = Path.basename(path)

      body =
        "--#{boundary}\r\n" <>
          "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" <>
          "Content-Type: application/octet-stream\r\n\r\n" <>
          file_data <>
          "\r\n--#{boundary}\r\n" <>
          "Content-Disposition: form-data; name=\"model\"\r\n\r\n" <>
          "whisper-1\r\n--#{boundary}--\r\n"

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "multipart/form-data; boundary=#{boundary}"}
      ]

      case Req.post(url, headers: headers, body: body, retry: false) do
        {:ok, %{status: 200, body: %{"text" => text}}} -> {:ok, text}
        {:ok, %{body: body}} -> {:error, {:whisper_error, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

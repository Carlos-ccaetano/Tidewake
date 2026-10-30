defmodule Tidewake.Webhooks.ManualRetryActor do
  @moduledoc """
  Carries an already authenticated actor and the trusted operation source.

  This structure authenticates nobody and grants no authorization. Only a trusted
  authentication boundary may construct it from server-side principal data; actor
  fields from an HTTP payload must never be passed directly to this constructor.
  Legacy shared bearer tokens do not provide sufficient actor identity.

  Subjects are stable opaque identifiers, never tokens, email addresses, personal
  names, or free-form metadata. The constructor checks UTF-8 identifier shape and
  byte bounds, preserving the original case and bytes. Letters, numbers, periods,
  underscores, colons, and hyphens are allowed. The trusted boundary must guarantee
  stability and provenance: shape validation cannot distinguish an identifier
  from a credential with the same shape.

  The public retry command accepts authenticated Scope and derives this struct
  internally. Constructing a struct alone is not proof of authentication. None of its
  values may enter Telemetry measurements, metadata, tags, or event names.
  """

  @actor_types ~w(service_account user)
  @sources ~w(api liveview admin_cli)
  @maximum_subject_size 255
  @subject_format ~r/\A[\p{L}\p{N}._:-]+\z/u

  @enforce_keys [:type, :subject, :source]
  @derive {Inspect, except: [:subject]}
  defstruct [:type, :subject, :source]

  @type t :: %__MODULE__{type: String.t(), subject: String.t(), source: String.t()}

  @doc """
  Builds actor context from exactly the atom keys `:type`, `:subject`, and `:source`.

  Type and source use the documented string vocabularies. Missing keys, extra
  keys, string-keyed request maps, structs, and malformed values fail closed.
  """
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_actor}
  def new(%{type: type, subject: subject, source: source} = attrs)
      when map_size(attrs) == 3 and type in @actor_types and source in @sources do
    if valid_subject?(subject),
      do: {:ok, %__MODULE__{type: type, subject: subject, source: source}},
      else: {:error, :invalid_actor}
  end

  def new(_attrs), do: {:error, :invalid_actor}

  defp valid_subject?(subject)
       when is_binary(subject) and byte_size(subject) > 0 and
              byte_size(subject) <= @maximum_subject_size do
    String.valid?(subject) and Regex.match?(@subject_format, subject)
  end

  defp valid_subject?(_subject), do: false
end

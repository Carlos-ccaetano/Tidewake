defmodule Tidewake.Projects.ServiceAccountTokenTest do
  use ExUnit.Case, async: false

  alias Tidewake.Projects.ServiceAccountToken, as: Token

  @uuid "00000000-0000-4000-8000-000000000001"
  @pepper String.duplicate("p", 32)
  @token "twk_sa." <> @uuid <> "." <> String.duplicate("A", 43)

  setup do
    previous = Application.fetch_env(:tidewake, :service_account_token_pepper)
    Application.put_env(:tidewake, :service_account_token_pepper, @pepper)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tidewake, :service_account_token_pepper, value)
        :error -> Application.delete_env(:tidewake, :service_account_token_pepper)
      end
    end)
  end

  test "canonical vector has exact size and an independently calculated HMAC" do
    assert byte_size(@token) == 87
    assert Token.parse(@token) == {:ok, @uuid}
    assert {:ok, digest} = Token.digest(@token, @pepper)
    assert byte_size(digest) == 32

    assert Base.encode16(digest, case: :lower) ==
             "c74fa1dff2b3df449956c4650f8980ff5b2f0b5861fbfb1c5aad74410ea2f75a"
  end

  test "parser rejects alternate encodings, malformed fields, and extra bytes" do
    secret = String.duplicate("A", 43)
    prefix = "twk_sa." <> @uuid <> "."
    invalid_uuid = "ABCDEF01-2345-4678-89AB-ABCDEF012345"

    for token <- [
          nil,
          123,
          %{},
          "",
          "TWK_SA." <> @uuid <> "." <> secret,
          "twk_sa." <> invalid_uuid <> "." <> secret,
          "twk_sa.not-a-uuid." <> secret,
          "twk_sa." <> String.duplicate("g", 36) <> "." <> secret,
          " " <> @token,
          @token <> " ",
          @token <> "\n",
          @token <> ".extra",
          prefix <> secret <> "=",
          prefix <> String.duplicate("A", 42),
          prefix <> String.duplicate("A", 44),
          prefix <> String.duplicate("A", 42) <> "B",
          prefix <> "+" <> String.duplicate("A", 42),
          prefix <> "/" <> String.duplicate("A", 42),
          prefix <> " " <> String.duplicate("A", 42),
          prefix <> "é" <> String.duplicate("A", 41),
          prefix <> String.duplicate("A", 42) <> <<255>>
        ] do
      assert Token.parse(token) == {:error, :invalid_token}
    end
  end

  test "generation calls the cryptographic RNG with 32 bytes before encoding" do
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :generate -> Token.generate(@uuid)
        after
          5_000 -> flunk("generation barrier timed out")
        end
      end)

    :erlang.trace_pattern({:crypto, :strong_rand_bytes, 1}, true, [])
    on_exit(fn -> :erlang.trace_pattern({:crypto, :strong_rand_bytes, 1}, false, []) end)
    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :generate)
    assert {:ok, generated} = Task.await(task)
    pid = task.pid
    assert_receive {:trace, ^pid, :call, {:crypto, :strong_rand_bytes, [32]}}
    assert Token.parse(generated.token) == {:ok, @uuid}
    ["twk_sa", @uuid, encoded] = String.split(generated.token, ".")
    assert byte_size(encoded) == 43
    assert byte_size(Base.url_decode64!(encoded, padding: false)) == 32
    assert byte_size(generated.token) == 87
    assert byte_size(generated.digest) == 32
    assert {:ok, other} = Token.generate(@uuid)
    refute other.token == generated.token
  end

  test "generation and digest never expose secrets through Inspect" do
    assert {:ok, generated} = Token.generate(@uuid)
    refute inspect(generated) =~ generated.token
    refute inspect(generated) =~ inspect(generated.digest)
    refute inspect(generated) =~ @pepper
  end

  test "digest covers the complete token and changes when token or pepper changes" do
    assert {:ok, first} = Token.digest(@token, @pepper)
    assert Token.digest(@token, @pepper) == {:ok, first}
    other_uuid = "00000000-0000-4000-8000-000000000002"
    other_secret = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

    for {token, pepper} <- [
          {String.replace(@token, @uuid, other_uuid), @pepper},
          {"twk_sa." <> @uuid <> "." <> other_secret, @pepper},
          {@token, String.duplicate("q", 32)}
        ] do
      assert {:ok, changed} = Token.digest(token, pepper)
      refute changed == first
    end

    assert Token.digest("not-canonical", @pepper) == {:error, :invalid_token}
  end

  test "secure comparison accepts only two 32-byte digests" do
    digest = :binary.copy(<<1>>, 32)
    assert Token.secure_match?(digest, digest)
    refute Token.secure_match?(digest, :binary.copy(<<2>>, 32))

    for invalid <- [nil, 42, "", :binary.copy(<<1>>, 31), :binary.copy(<<1>>, 33)] do
      refute Token.secure_match?(digest, invalid)
      refute Token.secure_match?(invalid, digest)
    end
  end

  test "missing and invalid pepper fail closed without echoing their values" do
    for pepper <- [nil, 42, "", String.duplicate("s", 31)] do
      Application.put_env(:tidewake, :service_account_token_pepper, pepper)
      assert Token.generate(@uuid) == {:error, :invalid_pepper}
      assert Token.digest(@token) == {:error, :invalid_pepper}
    end

    Application.delete_env(:tidewake, :service_account_token_pepper)
    assert Token.generate(@uuid) == {:error, :invalid_pepper}
    assert Token.digest(@token) == {:error, :invalid_pepper}
  end

  test "generation never normalizes invalid UUIDs" do
    for uuid <- [
          nil,
          123,
          "bad",
          " " <> @uuid,
          String.replace(@uuid, "-", ""),
          "ABCDEF01-2345-4678-89AB-ABCDEF012345"
        ] do
      assert Token.generate(uuid) == {:error, :invalid_token}
    end
  end
end

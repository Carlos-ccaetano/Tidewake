defmodule Tidewake.Webhooks.ManualRetryActorTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.ManualRetryActor

  test "accepts each actor type and operation source" do
    for type <- ~w(service_account user), source <- ~w(api liveview admin_cli) do
      assert {:ok, %ManualRetryActor{} = actor} =
               ManualRetryActor.new(%{type: type, subject: "opaque-actor-001", source: source})

      assert actor.type == type
      assert actor.source == source
      assert actor.subject == "opaque-actor-001"
    end
  end

  test "preserves the original case and bytes of opaque subjects" do
    for subject <- [
          "actor-001",
          "7fb0d9f3-475a-40f4-9641-64976cb3389e",
          "Tenant:Actor_01.v2",
          "actor:é42"
        ] do
      assert {:ok, actor} = ManualRetryActor.new(valid_attrs(%{subject: subject}))
      assert actor.subject == subject
    end
  end

  test "accepts one-byte and 255-byte subjects" do
    for size <- [1, 255] do
      subject = String.duplicate("x", size)
      assert {:ok, actor} = ManualRetryActor.new(valid_attrs(%{subject: subject}))
      assert byte_size(actor.subject) == size
    end
  end

  test "bounds multibyte subjects by bytes rather than characters" do
    subject = String.duplicate("é", 127) <> "x"
    assert byte_size(subject) == 255
    assert {:ok, actor} = ManualRetryActor.new(valid_attrs(%{subject: subject}))
    assert actor.subject == subject

    assert ManualRetryActor.new(valid_attrs(%{subject: String.duplicate("é", 128)})) ==
             {:error, :invalid_actor}
  end

  test "rejects subjects above the byte limit" do
    for size <- [256, 1024] do
      assert ManualRetryActor.new(valid_attrs(%{subject: String.duplicate("x", size)})) ==
               {:error, :invalid_actor}
    end
  end

  test "rejects empty, blank, control-containing, and malformed UTF-8 subjects" do
    for subject <- [
          "",
          " ",
          "\t\n",
          " actor",
          "actor ",
          "actor name",
          "actor\nname",
          "actor\0",
          "actor\u200B",
          <<255>>
        ] do
      assert ManualRetryActor.new(valid_attrs(%{subject: subject})) == {:error, :invalid_actor}
    end
  end

  test "rejects email addresses and authorization-header values as subjects" do
    for subject <- [
          "actor@example.invalid",
          "Name <actor@example.invalid>",
          "Bearer test-only-credential",
          "Basic dGVzdDpjcmVkZW50aWFs"
        ] do
      assert ManualRetryActor.new(valid_attrs(%{subject: subject})) == {:error, :invalid_actor}
    end
  end

  test "rejects URLs and serialized free-form metadata as subjects" do
    for subject <- [
          "https://identity.invalid/actors/123",
          ~s({"actor":"opaque-001"}),
          "actor=opaque-001&role=admin",
          "[opaque-001]"
        ] do
      assert ManualRetryActor.new(valid_attrs(%{subject: subject})) == {:error, :invalid_actor}
    end
  end

  test "rejects non-binary subjects" do
    for subject <- [
          nil,
          true,
          :actor,
          123,
          1.5,
          [],
          ~c"opaque-001",
          %{},
          {"opaque-001"},
          <<1::size(1)>>
        ] do
      assert ManualRetryActor.new(valid_attrs(%{subject: subject})) == {:error, :invalid_actor}
    end
  end

  test "rejects unknown or incorrectly typed actor types" do
    for type <- ["admin", "User", " user", "user ", "", :user, nil, 1, true, [], %{}] do
      assert ManualRetryActor.new(valid_attrs(%{type: type})) == {:error, :invalid_actor}
    end
  end

  test "rejects unknown or incorrectly typed sources" do
    for source <- ["web", "API", " api", "api ", "", :api, nil, 1, true, [], %{}] do
      assert ManualRetryActor.new(valid_attrs(%{source: source})) == {:error, :invalid_actor}
    end
  end

  test "requires all three keys" do
    for key <- [:type, :subject, :source] do
      assert valid_attrs() |> Map.delete(key) |> ManualRetryActor.new() ==
               {:error, :invalid_actor}
    end

    assert ManualRetryActor.new(%{}) == {:error, :invalid_actor}
  end

  test "fails closed for extra fields including credentials and metadata" do
    for {key, value} <- [
          token: "test-only-credential",
          secret: "test-only-secret",
          authorization: "Bearer test-only-credential",
          metadata: %{role: "admin"},
          role: "admin",
          ignored: nil
        ] do
      assert valid_attrs() |> Map.put(key, value) |> ManualRetryActor.new() ==
               {:error, :invalid_actor}
    end
  end

  test "rejects request maps with string keys, mixed keys, or aliases" do
    for attrs <- [
          %{"type" => "user", "subject" => "opaque-001", "source" => "api"},
          %{:type => "user", :subject => "opaque-001", "source" => "api"},
          %{actor_type: "user", actor_subject: "opaque-001", source: "api"}
        ] do
      assert ManualRetryActor.new(attrs) == {:error, :invalid_actor}
    end
  end

  test "rejects non-map inputs and does not treat structs as constructor attributes" do
    assert {:ok, actor} = ManualRetryActor.new(valid_attrs())

    for attrs <- [
          nil,
          true,
          :actor,
          "opaque-001",
          123,
          [],
          Map.to_list(valid_attrs()),
          actor,
          DateTime.utc_now()
        ] do
      assert ManualRetryActor.new(attrs) == {:error, :invalid_actor}
    end
  end

  test "carries only actor type, opaque subject, and source without credential fields" do
    assert {:ok, actor} = ManualRetryActor.new(valid_attrs())
    assert Map.from_struct(actor) == valid_attrs()
    assert Enum.sort(Map.keys(actor)) == [:__struct__, :source, :subject, :type]

    for field <- [:secret, :token, :authorization, :raw_key, :metadata] do
      refute Map.has_key?(actor, field)
    end
  end

  test "omits the protected subject from accidental inspection" do
    assert {:ok, actor} = ManualRetryActor.new(valid_attrs())
    refute inspect(actor) =~ actor.subject
    refute inspect({:ok, actor}, pretty: true, limit: :infinity) =~ actor.subject
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{type: "service_account", subject: "opaque-private-actor-001", source: "api"},
      overrides
    )
  end
end

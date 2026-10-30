defmodule Tidewake.Webhooks.ManualRetryIdempotencyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Tidewake.Webhooks.ManualRetryIdempotency

  @key "0123456789abcdef"
  @alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"
  @delivery_123_fingerprint "0457a4a758ffe5b92a5e165b0a8bc62938ca484b7fc5971ef67ad1ee6f4cea6b"
  @project "123e4567-e89b-12d3-a456-426614174000"
  @other_project "123e4567-e89b-12d3-a456-426614174001"
  @v2_fingerprint "97832941ee69a5e6cfab645e824961a1be8ab7cc19f934e5e9efbb3eda955080"
  @key_digest "9f9f5111f7b27a781f1f1ddde5ebc2dd2b796bfc7365c9c28b548e564176929f"

  describe "prepare/2" do
    test "accepts the inclusive 16-byte and 128-byte limits" do
      for size <- [16, 128] do
        assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, String.duplicate("a", size))
        assert byte_size(prepared.idempotency_key_digest) == 64
        assert prepared.request_fingerprint == @delivery_123_fingerprint
      end
    end

    test "rejects keys shorter than 16 bytes or longer than 128 bytes" do
      for size <- [0, 1, 15, 129, 1024] do
        assert ManualRetryIdempotency.prepare(123, String.duplicate("a", size)) ==
                 {:error, :invalid_idempotency_key}
      end
    end

    test "accepts every allowed ASCII character without requiring alphanumeric boundaries" do
      assert {:ok, _prepared} = ManualRetryIdempotency.prepare(123, @alphabet)

      for <<character <- @alphabet>> do
        assert {:ok, _prepared} =
                 ManualRetryIdempotency.prepare(123, :binary.copy(<<character>>, 16))
      end
    end

    test "rejects every byte outside the allowed ASCII alphabet" do
      allowed_bytes = :binary.bin_to_list(@alphabet)

      for byte <- 0..255, byte not in allowed_bytes do
        assert ManualRetryIdempotency.prepare(123, @key <> <<byte>>) ==
                 {:error, :invalid_idempotency_key}
      end
    end

    test "rejects Unicode and multibyte keys even when their byte length is valid" do
      for key <- [
            String.duplicate("é", 8),
            String.duplicate("Ω", 16),
            String.duplicate("🔑", 4),
            @key <> "\u200B",
            @key <> "e\u0301"
          ] do
        assert byte_size(key) in 16..128
        assert ManualRetryIdempotency.prepare(123, key) == {:error, :invalid_idempotency_key}
      end
    end

    test "rejects spaces and controls at either boundary without trimming" do
      for boundary <- [" ", "\t", "\r", "\n", <<0>>, <<127>>],
          key <- [boundary <> @key, @key <> boundary] do
        assert ManualRetryIdempotency.prepare(123, key) == {:error, :invalid_idempotency_key}
      end
    end

    test "rejects non-binary keys without raising or returning the supplied value" do
      for key <- [nil, 123, true, :key, [], ~c"0123456789abcdef", %{}, {@key}, <<1::size(1)>>] do
        assert ManualRetryIdempotency.prepare(123, key) == {:error, :invalid_idempotency_key}
      end
    end

    test "accepts positive integer delivery IDs" do
      for delivery_id <- [1, 123, 9_223_372_036_854_775_807] do
        assert {:ok, _prepared} = ManualRetryIdempotency.prepare(delivery_id, @key)
      end
    end

    test "rejects invalid delivery IDs without parsing or coercing them" do
      for delivery_id <- [0, -1, nil, 1.0, "123", "00123", "", true, :delivery, %{}, [1], {123}] do
        assert ManualRetryIdempotency.prepare(delivery_id, @key) == {:error, :invalid_delivery_id}
      end
    end

    test "returns invalid_delivery_id when both inputs are invalid" do
      assert ManualRetryIdempotency.prepare(0, nil) == {:error, :invalid_delivery_id}
    end

    test "is deterministic for identical input" do
      assert {:ok, first} = ManualRetryIdempotency.prepare(123, @key)
      assert ManualRetryIdempotency.prepare(123, @key) == {:ok, first}
    end

    test "changing the delivery ID changes only the fingerprint" do
      assert {:ok, first} = ManualRetryIdempotency.prepare(123, @key)
      assert {:ok, second} = ManualRetryIdempotency.prepare(124, @key)
      assert first.idempotency_key_digest == second.idempotency_key_digest
      refute first.request_fingerprint == second.request_fingerprint
    end

    test "changing the key changes only the key digest" do
      assert {:ok, first} = ManualRetryIdempotency.prepare(123, @key)
      assert {:ok, second} = ManualRetryIdempotency.prepare(123, "0123456789abcdeg")
      refute first.idempotency_key_digest == second.idempotency_key_digest
      assert first.request_fingerprint == second.request_fingerprint
    end

    test "preserves case in the exact key bytes" do
      assert {:ok, lower} = ManualRetryIdempotency.prepare(123, String.duplicate("a", 16))
      assert {:ok, upper} = ManualRetryIdempotency.prepare(123, String.duplicate("A", 16))
      refute lower.idempotency_key_digest == upper.idempotency_key_digest
      assert lower.request_fingerprint == upper.request_fingerprint
    end

    test "locks the exact versioned decimal delivery fingerprint to an independent vector" do
      assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, @key)
      assert prepared.request_fingerprint == @delivery_123_fingerprint
    end

    test "matches the standard 56-byte SHA-256 test vector" do
      key = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      assert byte_size(key) == 56
      assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, key)

      assert prepared.idempotency_key_digest ==
               "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

      assert prepared.request_fingerprint == @delivery_123_fingerprint
    end

    test "returns two 64-byte digests, an explicit version and no raw key" do
      key = String.duplicate("private-key._~-", 8)
      assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, key)

      assert Enum.sort(Map.keys(prepared)) ==
               [:idempotency_key_digest, :request_fingerprint, :request_fingerprint_version]

      assert prepared.request_fingerprint_version == 1

      for digest <-
            Map.values(Map.take(prepared, [:idempotency_key_digest, :request_fingerprint])) do
        assert byte_size(digest) == 64
        assert digest =~ ~r/\A[0-9a-f]{64}\z/
        refute digest == key
      end

      refute inspect(prepared) =~ key
    end

    test "does not log successful preparation, validation errors, or comparisons" do
      assert capture_log(fn ->
               assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, @key)

               assert {:error, :invalid_idempotency_key} =
                        ManualRetryIdempotency.prepare(123, @key <> " ")

               assert {:error, :invalid_delivery_id} = ManualRetryIdempotency.prepare(0, @key)

               assert ManualRetryIdempotency.same_fingerprint?(
                        prepared.request_fingerprint,
                        prepared.request_fingerprint
                      )
             end) == ""
    end
  end

  describe "versioned preparation and replay" do
    test "preserves independent v1 golden vectors byte for byte" do
      # These vectors were calculated independently with Python hashlib.sha256.
      for {id, expected} <- [
            {1, "0fe2dcd3794dfdea5de12991a804a28827e350fa34d97f4af8dd0cf7f25aee86"},
            {123, @delivery_123_fingerprint},
            {9_223_372_036_854_775_807,
             "edb37f3bf53ab011c94f255116c268fba4fc0cc511630ccecce4cd0edf6490cc"}
          ] do
        assert {:ok, prepared} = ManualRetryIdempotency.prepare(id, @key)

        assert prepared == %{
                 idempotency_key_digest: @key_digest,
                 request_fingerprint: expected,
                 request_fingerprint_version: 1
               }

        assert ManualRetryIdempotency.same_request?(prepared, prepared)
      end
    end

    test "locks the exact project-scoped v2 bytes to independent golden vectors" do
      for {project, id, expected} <- [
            {@project, 123, @v2_fingerprint},
            {@other_project, 123,
             "f77772967ed2e626fed008740bc9067d07d478f318043761d359fc1f1fcd1154"},
            {@project, 124, "df9e885e1ed11ce6dd64a5888fce6efdeeccbe62e94444973df30f9e0ef1ccb0"},
            {@project, 9_223_372_036_854_775_807,
             "cec150afce919278b0017cf130635f69db93ca4410e9098c13324d9703d138af"}
          ] do
        assert {:ok, prepared} = ManualRetryIdempotency.prepare(project, id, @key)

        assert prepared == %{
                 idempotency_key_digest: @key_digest,
                 request_fingerprint: expected,
                 request_fingerprint_version: 2
               }

        assert ManualRetryIdempotency.same_request?(prepared, prepared)
      end
    end

    test "the same key conflicts across delivery, project and fingerprint versions" do
      assert {:ok, original} = ManualRetryIdempotency.prepare(@project, 123, @key)
      assert {:ok, different_key} = ManualRetryIdempotency.prepare(@project, 123, @alphabet)
      assert ManualRetryIdempotency.same_request?(original, different_key)

      for {project, id} <- [{@other_project, 123}, {@project, 124}] do
        assert {:ok, other} = ManualRetryIdempotency.prepare(project, id, @key)
        assert original.idempotency_key_digest == other.idempotency_key_digest
        refute ManualRetryIdempotency.same_request?(original, other)
        refute ManualRetryIdempotency.same_request?(other, original)
      end

      legacy = %{original | request_fingerprint_version: 1}
      refute ManualRetryIdempotency.same_request?(legacy, original)
      refute ManualRetryIdempotency.same_request?(original, legacy)
    end

    test "rejects unsupported stored versions and malformed records without raising" do
      assert {:ok, prepared} = ManualRetryIdempotency.prepare(@project, 123, @key)

      for version <- [nil, 0, 3, -1, 1.0, 2.0, "2", :unknown] do
        unknown = %{prepared | request_fingerprint_version: version}
        refute ManualRetryIdempotency.same_request?(unknown, prepared)
        refute ManualRetryIdempotency.same_request?(prepared, unknown)
        refute ManualRetryIdempotency.same_request?(unknown, unknown)
      end

      for malformed <- [nil, %{}, @key, %{prepared | request_fingerprint: nil}] do
        refute ManualRetryIdempotency.same_request?(malformed, prepared)
        refute ManualRetryIdempotency.same_request?(prepared, malformed)
      end
    end

    test "rejects noncanonical project UUIDs instead of interpreting caller variants" do
      for project <- [
            nil,
            1,
            %{},
            <<0::128>>,
            String.upcase(@project),
            String.replace(@project, "-", ""),
            " " <> @project,
            @project <> "\n",
            "123e4567-e89b-12d3-a456-42661417400g"
          ] do
        assert ManualRetryIdempotency.prepare(project, 123, @key) ==
                 {:error, :invalid_project_public_id}
      end

      for id <- [0, -1, nil, 1.0, "123", "00123"] do
        assert ManualRetryIdempotency.prepare(@project, id, @key) ==
                 {:error, :invalid_delivery_id}
      end

      assert ManualRetryIdempotency.prepare(nil, 0, nil) == {:error, :invalid_delivery_id}
      assert ManualRetryIdempotency.prepare(nil, 123, nil) == {:error, :invalid_project_public_id}
    end

    test "v2 retains bounded key validation and exposes no raw key in results or logs" do
      handler = "fingerprint-privacy-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          handler,
          [[:tidewake, :repo, :query], [:tidewake, :webhooks, :manual_retry, :completed]],
          fn event, _measurements, _metadata, _config ->
            send(parent, {:fingerprint_event, event})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert capture_log(fn ->
               for size <- [16, 128] do
                 key = String.duplicate("private-key._~-", size) |> binary_part(0, size)
                 assert {:ok, prepared} = ManualRetryIdempotency.prepare(@project, 123, key)
                 refute String.contains?(inspect(prepared), key)
                 refute String.contains?(inspect(prepared), @project)
               end

               for key <- [
                     nil,
                     "",
                     String.duplicate("a", 15),
                     String.duplicate("a", 129),
                     @key <> " ",
                     @key <> "\n",
                     String.duplicate("é", 16)
                   ] do
                 assert ManualRetryIdempotency.prepare(@project, 123, key) ==
                          {:error, :invalid_idempotency_key}
               end
             end) == ""

      refute_received {:fingerprint_event, _event}
    end

    test "both versions delegate equal and different digests to secure_compare" do
      supervisor = start_supervised!(Task.Supervisor)
      Code.ensure_loaded!(Plug.Crypto)
      :erlang.trace_pattern({Plug.Crypto, :secure_compare, 2}, true, [])
      on_exit(fn -> :erlang.trace_pattern({Plug.Crypto, :secure_compare, 2}, false, []) end)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            :compare ->
              for version <- [1, 2] do
                original = %{
                  request_fingerprint_version: version,
                  request_fingerprint: @v2_fingerprint
                }

                other = %{original | request_fingerprint: @delivery_123_fingerprint}

                {ManualRetryIdempotency.same_request?(original, original),
                 ManualRetryIdempotency.same_request?(original, other)}
              end
          end
        end)

      :erlang.trace(task.pid, true, [:call])
      send(task.pid, :compare)
      assert Task.await(task) == [{true, false}, {true, false}]
      pid = task.pid

      for _version <- [1, 2] do
        assert_receive {:trace, ^pid, :call,
                        {Plug.Crypto, :secure_compare, [@v2_fingerprint, @v2_fingerprint]}}

        assert_receive {:trace, ^pid, :call,
                        {Plug.Crypto, :secure_compare,
                         [@v2_fingerprint, @delivery_123_fingerprint]}}
      end
    end
  end

  describe "same_fingerprint?/2" do
    test "matches equal prepared fingerprints independently of the key" do
      assert {:ok, first} = ManualRetryIdempotency.prepare(123, @key)
      assert {:ok, second} = ManualRetryIdempotency.prepare(123, String.duplicate("b", 128))

      assert ManualRetryIdempotency.same_fingerprint?(
               first.request_fingerprint,
               second.request_fingerprint
             )
    end

    test "rejects different prepared fingerprints" do
      assert {:ok, first} = ManualRetryIdempotency.prepare(123, @key)
      assert {:ok, second} = ManualRetryIdempotency.prepare(124, @key)

      refute ManualRetryIdempotency.same_fingerprint?(
               first.request_fingerprint,
               second.request_fingerprint
             )

      refute ManualRetryIdempotency.same_fingerprint?(
               second.request_fingerprint,
               first.request_fingerprint
             )
    end

    test "compares the entire fixed size including its first, middle, and last bytes" do
      left = String.duplicate("a", 64)

      for position <- [0, 31, 63] do
        right =
          binary_part(left, 0, position) <> "b" <> binary_part(left, position + 1, 63 - position)

        refute ManualRetryIdempotency.same_fingerprint?(left, right)
        refute ManualRetryIdempotency.same_fingerprint?(right, left)
      end
    end

    test "rejects malformed or non-fixed-size fingerprints without raising" do
      valid = @delivery_123_fingerprint

      for invalid <- [
            nil,
            123,
            %{},
            [],
            <<1::size(1)>>,
            "",
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            String.duplicate("A", 64),
            String.duplicate("g", 64),
            :binary.copy(<<255>>, 64),
            <<0::size(256)>>,
            binary_part(valid, 0, 63) <> "\n"
          ] do
        refute ManualRetryIdempotency.same_fingerprint?(invalid, valid)
        refute ManualRetryIdempotency.same_fingerprint?(valid, invalid)
        refute ManualRetryIdempotency.same_fingerprint?(invalid, invalid)
      end
    end
  end
end

defmodule Tidewake.Webhooks.ManualRetryIdempotencyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Tidewake.Webhooks.ManualRetryIdempotency

  @key "0123456789abcdef"
  @alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"
  @delivery_123_fingerprint "0457a4a758ffe5b92a5e165b0a8bc62938ca484b7fc5971ef67ad1ee6f4cea6b"

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

    test "returns exactly two 64-byte lowercase hexadecimal digests and no raw key" do
      key = String.duplicate("private-key._~-", 8)
      assert {:ok, prepared} = ManualRetryIdempotency.prepare(123, key)
      assert Enum.sort(Map.keys(prepared)) == [:idempotency_key_digest, :request_fingerprint]

      for digest <- Map.values(prepared) do
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

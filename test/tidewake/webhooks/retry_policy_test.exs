defmodule Tidewake.Webhooks.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.RetryPolicy

  describe "max_attempts/0" do
    test "exposes the delivery attempt limit" do
      assert RetryPolicy.max_attempts() == 6
    end
  end

  describe "classify/2" do
    for status <- [200, 201, 204, 299] do
      test "classifies HTTP #{status} as succeeded at every valid attempt boundary" do
        outcome = %{result: "succeeded", http_status: unquote(status)}

        assert RetryPolicy.classify(outcome, 1) == :succeeded
        assert RetryPolicy.classify(outcome, 6) == :succeeded
      end
    end

    for status <- [408, 425, 429, 500, 502, 503, 504] do
      test "classifies retryable HTTP #{status} before and at the attempt limit" do
        outcome = %{result: "http_error", http_status: unquote(status)}

        assert RetryPolicy.classify(outcome, 5) == :retry
        assert RetryPolicy.classify(outcome, 6) == :exhausted
        assert RetryPolicy.classify(outcome, 7) == :exhausted
      end
    end

    for status <- [100, 199, 300, 400, 409, 501, 599] do
      test "classifies non-retryable HTTP #{status} as a permanent failure" do
        outcome = %{result: "http_error", http_status: unquote(status)}

        assert RetryPolicy.classify(outcome, 1) == :permanent_failure
        assert RetryPolicy.classify(outcome, 6) == :permanent_failure
      end
    end

    for error_type <- ~w(timeout dns connection closed) do
      test "classifies retryable transport error #{error_type} before and at the limit" do
        outcome = %{result: "transport_error", error_type: unquote(error_type)}

        assert RetryPolicy.classify(outcome, 5) == :retry
        assert RetryPolicy.classify(outcome, 6) == :exhausted
        assert RetryPolicy.classify(outcome, 8) == :exhausted
      end
    end

    for error_type <- ~w(tls destination response_limit unknown) do
      test "classifies terminal transport error #{error_type} as a permanent failure" do
        outcome = %{result: "transport_error", error_type: unquote(error_type)}

        assert RetryPolicy.classify(outcome, 1) == :permanent_failure
        assert RetryPolicy.classify(outcome, 6) == :permanent_failure
      end
    end

    test "fails closed for unknown or incomplete outcomes" do
      malformed_outcomes = [
        %{},
        %{result: "succeeded"},
        %{result: "succeeded", http_status: 500},
        %{result: "http_error"},
        %{result: "http_error", http_status: "503"},
        %{result: "transport_error"},
        %{result: "transport_error", error_type: :timeout},
        %{result: "unexpected", http_status: 503},
        nil
      ]

      for outcome <- malformed_outcomes do
        assert RetryPolicy.classify(outcome, 1) == :permanent_failure
      end
    end

    test "fails closed when the attempt number is not a positive integer" do
      outcome = %{result: "http_error", http_status: 503}

      for attempt_number <- [0, -1, 1.0, nil] do
        assert RetryPolicy.classify(outcome, attempt_number) == :permanent_failure
      end
    end
  end
end

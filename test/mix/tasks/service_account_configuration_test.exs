defmodule Tidewake.ServiceAccountConfigurationTest do
  use ExUnit.Case, async: false

  @key "TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER"

  test "production rejects missing, empty and short peppers without disclosing their value" do
    for pepper <- [nil, "", "private-short-pepper", String.duplicate("s", 31)] do
      with_env(prod_env(pepper), fn ->
        error = assert_raise RuntimeError, fn -> runtime(:prod) end
        assert error.message == "#{@key} must contain at least 32 bytes"
        if pepper not in [nil, ""], do: refute(error.message =~ pepper)
      end)
    end
  end

  test "production accepts at least 32 bytes and preserves the transitional static token" do
    for pepper <- [
          String.duplicate("p", 32),
          String.duplicate("é", 16),
          String.duplicate("p", 64)
        ] do
      with_env(prod_env(pepper), fn ->
        config = runtime(:prod)
        assert config[:service_account_token_pepper] == pepper
        assert config[:api_token] == String.duplicate("a", 32)
      end)
    end
  end

  test "development and test provide explicit non-production values of at least 32 bytes" do
    with_env(%{@key => nil}, fn ->
      for env <- [:dev, :test] do
        config = Config.Reader.read!("config/#{env}.exs", env: env) |> Keyword.fetch!(:tidewake)
        pepper = Keyword.fetch!(config, :service_account_token_pepper)
        assert byte_size(pepper) >= 32
        assert pepper =~ "#{env}-only"
        assert pepper =~ "not-for-production"
      end
    end)
  end

  test "runtime rejects invalid local configuration without printing its value" do
    previous = Application.fetch_env!(:tidewake, :service_account_token_pepper)

    try do
      Application.put_env(:tidewake, :service_account_token_pepper, "local-private-short")
      error = assert_raise RuntimeError, fn -> runtime(:test) end
      assert error.message == "#{@key} must contain at least 32 bytes"
    after
      Application.put_env(:tidewake, :service_account_token_pepper, previous)
    end
  end

  defp runtime(env) do
    Config.Reader.read!("config/runtime.exs", env: env) |> Keyword.fetch!(:tidewake)
  end

  defp prod_env(pepper) do
    %{
      @key => pepper,
      "TIDEWAKE_API_TOKEN" => String.duplicate("a", 32),
      "TIDEWAKE_WEBHOOK_SIGNING_SECRET" => String.duplicate("w", 32),
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/tidewake_test",
      "SECRET_KEY_BASE" => String.duplicate("k", 64),
      "PORT" => "4000"
    }
  end

  defp with_env(values, fun) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(values, &set_env/1)
      fun.()
    after
      Enum.each(previous, &set_env/1)
    end
  end

  defp set_env({key, nil}), do: System.delete_env(key)
  defp set_env({key, value}), do: System.put_env(key, value)
end

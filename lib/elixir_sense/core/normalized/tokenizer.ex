defmodule ElixirSense.Core.Normalized.Tokenizer do
  @moduledoc """
  Handles tokenization of Elixir code snippets

  Uses private api :elixir_tokenizer
  """

  @spec tokenize(String.t()) :: [tuple]
  def tokenize(prefix) do
    prefix
    |> String.to_charlist()
    |> do_tokenize(System.version())
  end

  defp do_tokenize(prefix_charlist, elixir_version) do
    if Version.match?(elixir_version, ">= 1.7.0") do
      do_tokenize_1_7(prefix_charlist)
    else
      do_tokenize_1_6(prefix_charlist)
    end
  end

  defp do_tokenize_1_7(prefix_charlist) do
    case :elixir_tokenizer.tokenize(prefix_charlist, 1, []) do
      {:ok, tokens} ->
        Enum.reverse(tokens)

      {:error, {_line, _column, _error_prefix, _token}, _rest, sofar} ->
        sofar
    end
  end

  defp do_tokenize_1_6(prefix_charlist) do
    case :elixir_tokenizer.tokenize(prefix_charlist, 1, []) do
      {:ok, tokens} ->
        Enum.reverse(tokens)

      {:error, _, _rest, sofar} ->
        sofar
    end
  end
end

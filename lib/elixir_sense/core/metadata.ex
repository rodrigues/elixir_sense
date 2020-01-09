defmodule ElixirSense.Core.Metadata do
  @moduledoc """
  Core Metadata
  """

  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Normalized.Code, as: NormalizedCode
  alias ElixirSense.Core.State
  alias ElixirSense.Core.TypeInfo

  @type t :: %ElixirSense.Core.Metadata{
          source: String.t(),
          mods_funs_to_positions: State.mods_funs_to_positions_t(),
          lines_to_env: State.lines_to_env_t(),
          calls: State.calls_t(),
          vars_info_per_scope_id: State.vars_info_per_scope_id_t(),
          types: State.types_t(),
          specs: State.specs_t(),
          structs: State.structs_t(),
          error: nil | term
        }

  defstruct source: "",
            mods_funs_to_positions: %{},
            lines_to_env: %{},
            calls: %{},
            vars_info_per_scope_id: %{},
            types: %{},
            specs: %{},
            structs: %{},
            error: nil

  @type signature_t :: %{
          name: String.t(),
          params: [String.t()],
          spec: String.t(),
          documentation: String.t()
        }

  @spec get_env(__MODULE__.t(), pos_integer) :: State.Env.t()
  def get_env(%__MODULE__{} = metadata, line) do
    case Map.get(metadata.lines_to_env, line) do
      nil -> State.default_env()
      ctx -> ctx
    end
  end

  def get_calls(%__MODULE__{} = metadata, line) do
    case Map.get(metadata.calls, line) do
      nil -> []
      calls -> Enum.sort_by(calls, fn %State.CallInfo{position: {_line, column}} -> column end)
    end
  end

  def get_call_arity(%__MODULE__{} = metadata, line, col) do
    calls = get_calls(metadata, line)

    case Enum.find(calls, fn %State.CallInfo{position: {_line, column}} -> column == col end) do
      %{arity: arity} -> arity
      _ -> nil
    end
  end

  def get_function_position(%__MODULE__{} = metadata, module, function) do
    case Map.get(metadata.mods_funs_to_positions, {module, function, nil}) do
      nil -> get_function_position_using_docs(module, function)
      %{positions: positions} -> List.last(positions)
    end
  end

  def get_type_position(%__MODULE__{} = metadata, module, type, file) do
    case Map.get(metadata.types, {module, type, nil}) do
      nil ->
        TypeInfo.get_type_position_using_docs(module, type, file)

      %ElixirSense.Core.State.TypeInfo{positions: [h | _t]} ->
        h
    end
  end

  def get_function_info(%__MODULE__{} = metadata, module, function) do
    case Map.get(metadata.mods_funs_to_positions, {module, function, nil}) do
      nil -> %{positions: [], params: []}
      info -> info
    end
  end

  def get_type_info(%__MODULE__{} = metadata, module, type) do
    case Map.get(metadata.types, {module, type, nil}) do
      nil -> %{lines: [], params: []}
      info -> info
    end
  end

  def get_function_params(%__MODULE__{} = metadata, module, function) do
    params =
      metadata
      |> get_function_info(module, function)
      |> Map.get(:params)
      |> Enum.reverse()

    Enum.map(params, fn param ->
      param
      |> Macro.to_string()
      |> String.slice(1..-2)
    end)
  end

  @spec get_function_signatures(__MODULE__.t(), module, atom) :: [signature_t]
  def get_function_signatures(%__MODULE__{} = metadata, module, function)
      when not is_nil(module) and not is_nil(function) do
    params_list =
      metadata
      |> get_function_info(module, function)
      |> Map.get(:params)
      |> Enum.reverse()

    Enum.map(params_list, fn params ->
      arity = length(params)

      spec =
        case metadata.specs[{module, function, arity}] do
          nil ->
            ""

          %State.SpecInfo{specs: specs} ->
            Enum.join(specs, "\n")
        end

      %{
        name: Atom.to_string(function),
        params: params |> Enum.with_index() |> Enum.map(&Introspection.param_to_var/1),
        documentation: "",
        spec: spec
      }
    end)
  end

  @spec get_type_signatures(__MODULE__.t(), module, atom) :: [signature_t]
  def get_type_signatures(%__MODULE__{} = metadata, module, type)
      when not is_nil(module) and not is_nil(type) do
    case Map.get(metadata.types, {module, type, nil}) do
      nil ->
        []

      %State.TypeInfo{args: args_variants} ->
        for args <- args_variants do
          arity = length(args)

          spec = metadata.types[{module, type, arity}].specs |> Enum.join("\n")

          %{
            name: Atom.to_string(type),
            params: args,
            documentation: "",
            spec: spec
          }
        end
    end
  end

  defp get_function_position_using_docs(module, function) do
    docs = NormalizedCode.get_docs(module, :docs)

    for {{func, _arity}, line, _kind, _, _} <- docs, func == function do
      {line, 1}
    end
    |> Enum.at(0)
  end
end

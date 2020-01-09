defmodule ElixirSense.Providers.Definition do
  @moduledoc """
  Provides a function to find out where symbols are defined.

  Currently finds definition of modules, functions and macros.
  """

  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Parser
  alias ElixirSense.Core.Source
  alias ElixirSense.Core.State
  alias ElixirSense.Core.State.ModFunInfo
  alias ElixirSense.Core.State.TypeInfo
  alias ElixirSense.Core.State.VarInfo

  defmodule Location do
    @moduledoc false

    @type t :: %Location{
            found: boolean,
            type: :module | :function | :variable | :typespec | :macro | nil,
            file: String.t() | nil,
            line: pos_integer | nil,
            column: pos_integer | nil
          }
    defstruct [:found, :type, :file, :line, :column]
  end

  @doc """
  Finds out where a module, function, macro or variable was defined.
  """
  @spec find(
          String.t(),
          State.Env.t(),
          State.mods_funs_to_positions_t(),
          list(State.CallInfo.t()),
          State.types_t()
        ) :: %Location{}
  def find(
        subject,
        %State.Env{imports: imports, aliases: aliases, module: module, vars: vars},
        mods_funs_to_positions,
        calls,
        metadata_types
      ) do
    var_info =
      unless subject_is_call?(subject, calls) do
        vars |> Enum.find(fn %VarInfo{name: name} -> to_string(name) == subject end)
      end

    case var_info do
      %VarInfo{positions: [{line, column} | _]} ->
        %Location{found: true, type: :variable, file: nil, line: line, column: column}

      _ ->
        subject
        |> Source.split_module_and_func(module, aliases)
        |> find_function_or_module(
          mods_funs_to_positions,
          module,
          imports,
          aliases,
          metadata_types
        )
    end
  end

  defp subject_is_call?(subject, calls) do
    Enum.find(calls, fn
      %{mod: nil, func: func} ->
        Atom.to_string(func) == subject

      _ ->
        false
    end) != nil
  end

  defp find_function_or_module(
         {module, function},
         mods_funs_to_positions,
         current_module,
         imports,
         aliases,
         metadata_types
       ) do
    case {module, function}
         |> Introspection.actual_mod_fun(
           imports,
           aliases,
           current_module,
           mods_funs_to_positions,
           metadata_types
         ) do
      {_, _, false} ->
        %Location{found: false}

      {mod, fun, true} ->
        case mods_funs_to_positions[{mod, fun, nil}] || metadata_types[{mod, fun, nil}] do
          nil ->
            {mod, fun} |> find_source(current_module)

          %TypeInfo{positions: positions} ->
            # for simplicity take last position here as positions are reversed
            {line, column} = positions |> Enum.at(-1)

            %Location{
              found: true,
              file: nil,
              type: :typespec,
              line: line,
              column: column
            }

          %ModFunInfo{positions: positions} = mi ->
            # for simplicity take last position here as positions are reversed
            {line, column} = positions |> Enum.at(-1)

            %Location{
              found: true,
              file: nil,
              type: ModFunInfo.get_category(mi),
              line: line,
              column: column
            }
        end
    end
  end

  defp find_source({mod, fun}, current_module) do
    with(
      {mod, file} when file not in ["non_existing", nil, ""] <- find_mod_file(mod),
      nil <- find_fun_position({mod, file}, fun),
      nil <- find_type_position({mod, file}, fun),
      nil <- find_type_position({current_module, file}, fun)
    ) do
      %Location{found: false}
    else
      %Location{} = location ->
        location

      _ ->
        %Location{found: false}
    end
  end

  defp find_mod_file(Elixir), do: nil

  defp find_mod_file(module) do
    file =
      if Code.ensure_loaded?(module) do
        case module.module_info(:compile)[:source] do
          nil -> nil
          source -> List.to_string(source)
        end
      end

    file =
      if file && File.exists?(file) do
        file
      else
        with {_module, _binary, beam_filename} <- :code.get_object_code(module),
             erl_file =
               beam_filename
               |> to_string
               |> String.replace(
                 Regex.recompile!(~r/(.+)\/ebin\/([^\s]+)\.beam$/),
                 "\\1/src/\\2.erl"
               ),
             true <- File.exists?(erl_file) do
          erl_file
        else
          _ -> nil
        end
      end

    {module, file}
  end

  defp find_fun_position({mod, file}, fun) do
    {position, category} =
      if String.ends_with?(file, ".erl") do
        # no macros in erlang modules, assume :function when fun != nil
        category = fun_to_type(fun)
        {find_fun_position_in_erl_file(file, fun), category}
      else
        %Metadata{mods_funs_to_positions: mods_funs_to_positions} =
          file_metadata = Parser.parse_file(file, false, false, nil)

        category =
          case mods_funs_to_positions[{mod, fun, nil}] do
            %ModFunInfo{} = mi ->
              ModFunInfo.get_category(mi)

            nil ->
              # not found, fall back to :function when fun != nil
              # TODO use docs?
              fun_to_type(fun)
          end

        {Metadata.get_function_position(file_metadata, mod, fun), category}
      end

    case position do
      {line, column} ->
        %Location{found: true, type: category, file: file, line: line, column: column}

      _ ->
        nil
    end
  end

  defp fun_to_type(nil), do: :module
  defp fun_to_type(_), do: :function

  defp find_fun_position_in_erl_file(_file, nil), do: {1, 1}

  defp find_fun_position_in_erl_file(file, name) do
    find_line_by_regex(file, Regex.recompile!(~r/^#{name}\b/))
  end

  defp find_type_position_in_erl_file(file, name) do
    find_line_by_regex(file, Regex.recompile!(~r/^-(typep?|opaque)\s#{name}\b/))
  end

  defp find_line_by_regex(file, regex) do
    index =
      file
      |> File.read!()
      |> String.split(["\n", "\r\n"])
      |> Enum.find_index(&String.match?(&1, regex))

    case index do
      nil -> nil
      i -> {i + 1, 1}
    end
  end

  defp find_type_position(_, nil), do: nil

  defp find_type_position({mod, file}, name) do
    position =
      if String.ends_with?(file, ".erl") do
        find_type_position_in_erl_file(file, name)
      else
        file_metadata = Parser.parse_file(file, false, false, nil)
        Metadata.get_type_position(file_metadata, mod, name, file)
      end

    case position do
      {line, column} ->
        %Location{found: true, type: :typespec, file: file, line: line, column: column}

      _ ->
        nil
    end
  end
end

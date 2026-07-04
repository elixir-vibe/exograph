defmodule Exograph.ElixirParser do
  @moduledoc false

  alias Exograph.Ident

  @fixed_atoms %{
    "__aliases__" => :__aliases__,
    "__block__" => :__block__,
    "__MODULE__" => :__MODULE__,
    "defmodule" => :defmodule,
    "def" => :def,
    "defp" => :defp,
    "defmacro" => :defmacro,
    "defmacrop" => :defmacrop,
    "defdelegate" => :defdelegate,
    "defexception" => :defexception,
    "defimpl" => :defimpl,
    "defprotocol" => :defprotocol,
    "defstruct" => :defstruct,
    "defoverridable" => :defoverridable,
    "defguard" => :defguard,
    "defguardp" => :defguardp,
    "defcallback" => :defcallback,
    "defmacrocallback" => :defmacrocallback,
    "if" => :if,
    "unless" => :unless,
    "case" => :case,
    "cond" => :cond,
    "receive" => :receive,
    "try" => :try,
    "with" => :with,
    "for" => :for,
    "fn" => :fn,
    "quote" => :quote,
    "unquote" => :unquote,
    "unquote_splicing" => :unquote_splicing,
    "require" => :require,
    "import" => :import,
    "alias" => :alias,
    "use" => :use,
    "super" => :super,
    "raise" => :raise,
    "reraise" => :reraise,
    "throw" => :throw,
    "exit" => :exit,
    "in" => :in,
    "not" => :not,
    "and" => :and,
    "or" => :or,
    "when" => :when,
    "|>" => :|>,
    "." => :.,
    "=" => :=,
    "%" => :%,
    "%{}" => :%{},
    "{}" => :{},
    "->" => :->,
    "&" => :&,
    "@" => :@,
    "::" => :"::",
    "|" => :|,
    "\\" => :\\,
    "..." => :...,
    "_" => :_
  }

  def string_to_quoted(source, opts \\ []) do
    Code.string_to_quoted(source, parser_opts(opts))
  end

  def string_to_quoted_with_comments(source, opts \\ []) do
    Code.string_to_quoted_with_comments(source, parser_opts(opts))
  end

  defp parser_opts(opts) do
    opts
    |> Keyword.delete(:static_atoms)
    |> Keyword.put(:static_atoms_encoder, &tagged_ident/2)
  end

  defp tagged_ident(name, _metadata) do
    {:ok, Map.get(@fixed_atoms, name, Ident.tag(name))}
  end
end

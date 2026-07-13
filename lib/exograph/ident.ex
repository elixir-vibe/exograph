defmodule Exograph.Ident do
  @moduledoc false

  @tag :__exograph_ident__

  @fixed_atoms %{
    "__aliases__" => :__aliases__,
    "__block__" => :__block__,
    "__MODULE__" => :__MODULE__,
    "__exograph_ident__" => :__exograph_ident__,
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
    "_" => :_,
    "line" => :line,
    "column" => :column,
    "end_line" => :end_line,
    "end_column" => :end_column,
    "closing" => :closing,
    "delimiter" => :delimiter,
    "do" => :do,
    "end" => :end,
    "end_of_expression" => :end_of_expression,
    "format" => :format,
    "generated" => :generated,
    "context" => :context,
    "counter" => :counter,
    "imported" => :imported,
    "no_parens" => :no_parens,
    "token" => :token
  }

  def tag(name) when is_binary(name), do: {@tag, name}

  def ident?({@tag, name}) when is_binary(name), do: true
  def ident?(_term), do: false

  def name({@tag, name}) when is_binary(name), do: name
  def name(atom) when is_atom(atom), do: Atom.to_string(atom)

  def fixed_atom(name) when is_binary(name), do: Map.fetch(@fixed_atoms, name)

  def static_atom(name) when is_binary(name) do
    case fixed_atom(name) do
      {:ok, atom} -> atom
      :error -> tag(name)
    end
  end

  def to_display({@tag, name}) when is_binary(name), do: name
  def to_display(atom) when is_atom(atom), do: Atom.to_string(atom)
  def to_display(binary) when is_binary(binary), do: binary
  def to_display(other), do: inspect(other)

  def equal?(left, right) when left == right, do: true

  def equal?(ident, atom) when is_atom(atom) do
    ident?(ident) and name(ident) == Atom.to_string(atom)
  end

  def equal?(atom, ident) when is_atom(atom), do: equal?(ident, atom)
  def equal?(_left, _right), do: false
end

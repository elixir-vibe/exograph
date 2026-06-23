defmodule Exograph.Storage.FragmentRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.Fragment

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_fragments" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:package_version, :string, virtual: true)
    field(:file_id, :integer)
    field(:file, :string, virtual: true)
    field(:source, :string, virtual: true)
    field(:content_hash, :binary)
    field(:ast, :binary)

    field(:kind, Ecto.Enum,
      values: [:unknown, :module, :expression, :def, :defp, :defmacro, :defmacrop]
    )

    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:line, :integer)
    field(:end_line, :integer)
    field(:mass, :integer)
    field(:exact_hash, :binary)
    field(:terms, {:array, :integer}, default: [])
    field(:sub_hashes, {:array, :integer}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:ast, :kind, :line, :mass])
  end

  def from_fragment(%Fragment{} = fragment) do
    %{
      package_id: fragment.package_id,
      package_version_id: fragment.package_version_id,
      file_id: fragment.file_id,
      content_hash: fragment.content_hash,
      ast: compressed_binary(fragment.ast),
      kind: fragment.kind,
      module: fragment.module,
      name: fragment.name,
      arity: fragment.arity,
      line: fragment.line,
      end_line: fragment.end_line,
      mass: fragment.mass,
      exact_hash: encode_hash(fragment.exact_hash),
      terms: MapSet.to_list(fragment.terms),
      sub_hashes: MapSet.to_list(fragment.sub_hashes)
    }
  end

  def to_fragment(%__MODULE__{} = record) do
    %Fragment{
      id: record.id,
      package_id: record.package_id,
      package_version_id: record.package_version_id,
      package_version: record.package_version,
      file_id: record.file_id,
      file: record.file,
      source: record.source,
      content_hash: record.content_hash,
      ast: :erlang.binary_to_term(record.ast),
      kind: record.kind,
      module: record.module,
      name: record.name,
      arity: record.arity,
      line: record.line,
      end_line: record.end_line,
      mass: record.mass,
      exact_hash: record.exact_hash,
      terms: mapset(record.terms),
      sub_hashes: mapset(record.sub_hashes)
    }
  end

  defp encode_hash(nil), do: nil

  defp encode_hash(hash) when is_binary(hash) do
    case Base.decode16(hash, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> hash
    end
  end

  defp encode_hash(hash), do: to_string(hash)

  defp compressed_binary(term), do: :erlang.term_to_binary(term, [:compressed])
  defp mapset(nil), do: MapSet.new()
  defp mapset(values), do: MapSet.new(values)
end

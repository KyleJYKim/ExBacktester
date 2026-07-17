defmodule ExBacktester.Data.CSV do
  @moduledoc """
  Loads daily OHLCV bars from a CSV file with the header:

      Date,Open,High,Low,Close,Volume

  This matches the export format of Stooq (stooq.com) and Yahoo Finance.
  Download data manually and drop it in priv/data/ — building an API
  client is explicitly out of scope for v0.1 (see README).
  """

  alias ExBacktester.Bar

  @spec load!(Path.t()) :: [Bar.t()]
  def load!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    # drop header row
    |> Stream.drop(1)
    |> Enum.map(&parse_line!/1)
    # oldest bar first — the feed replays them in chronological order
    |> Enum.sort_by(& &1.date, Date)
  end

  defp parse_line!(line) do
    case String.split(line, ",") do
      [date, open, high, low, close, volume] ->
        %Bar{
          date: Date.from_iso8601!(date),
          open: parse_float!(open),
          high: parse_float!(high),
          low: parse_float!(low),
          close: parse_float!(close),
          volume: parse_volume!(volume)
        }

      other ->
        raise ArgumentError,
              "expected 6 comma-separated fields, got #{length(other)}: #{inspect(line)}"
    end
  end

  defp parse_float!(s) do
    case Float.parse(s) do
      {f, _rest} -> f
      :error -> raise ArgumentError, "not a number: #{inspect(s)}"
    end
  end

  # Some sources export volume as "1234567.0"
  defp parse_volume!(s), do: s |> parse_float!() |> trunc()
end

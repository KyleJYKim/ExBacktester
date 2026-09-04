defmodule Mix.Tasks.Backtest do
  @shortdoc "Run a backtest over a CSV of daily bars"

  @moduledoc """
  Run one or both strategies over a CSV of daily OHLCV bars.

    mix backtest
    mix backtest --strategy sma
    mix backtest --data priv/data/sample.csv -- ticker SAMPLE --qty 50
    mix backtest --strategy sma --fast 5 --slow 20

  ## Options

    * `--data`      - path to the CSV (default `priv/data/sample.csv`)
    * `--ticker`    - ticker symbol to tag bars with (default `SAMPLE`)
    * `--strategy`  - `sma`, `meanrev`, or `both` (default `both`)
    * `--qty`       - shares per order (default 100)
    * `--fast`      - SMA fast window (default 10)
    * `--slow`      - SMA slow window (default 30)
    * `--window`    - mean-reversion lookback (default 20)
    * `--entry`     - mean-reversion entry z-score (default 2.0)

  The CSV must have the header `Date,Open,High,Low,Close,Volume`,
  which is what Stooq and Yahoo Finance export.
  Download data by hand and drop it in `priv/data/` - fetching it over the network is out of scope for v0.1.
  """

  use Mix.Task

  alias ExBacktester.Runner
  alias ExBacktester.Strategy.{SmaCrossover, MeanReversion}

  @switches [
    data: :string,
    ticker: :string,
    strategy: :string,
    qty: :integer,
    fast: :integer,
    slow: :integer,
    window: :integer,
    entry: :float
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      name = Enum.map_join(invalid, ", ", fn {name, _} -> name end)
      Mix.raise("unknonw or malformed option(s): #{name}\n\nSee: mix help. backtest")
    end

    # The app owns the supervision tree, so it must be running before any process (Broker, DataFeed, ...) can be called.
    Mix.Task.run("app.start")

    data = Keyword.get(opts, :data, "priv/data/sample.csv")
    ticker = Keyword.get(opts, :ticker, "SAMPLE")
    qty = Keyword.get(opts, :qty, 100)

    unless File.exists?(data) do
      Mix.raise("data file not found: #{data}")
    end

    specs = build_specs(Keyword.get(opts, :strategy, "both"), opts, ticker, qty)

    Runner.run(data, ticker, specs)
  end

  defp build_specs("sma", opts, ticker, qty), do: [sma_spec(opts, ticker, qty)]
  defp build_specs("meanrev", opts, ticker, qty), do: [meanrev_spec(opts, ticker, qty)]
  defp build_specs("both", opts, ticker, qty), do: [sma_spec(opts, ticker, qty), meanrev_spec(opts, ticker, qty)]
  defp build_specs(other, _opts, _ticker, _qty) do
    Mix.raise("unknown strategy #{inspect(other)} - expected sma, meanrev, or both")
  end

  defp sma_spec(opts, ticker, qty) do
    fast = Keyword.get(opts, :fast, 10)
    slow = Keyword.get(opts, :slow, 30)

    if fast >= slow do
      Mix.raise("--fast (#{fast}) must be smaller than --slow (#{slow})")
    end

    {SmaCrossover,
      [
        name: :"sma_#{fast}_#{slow}",
        ticker: ticker,
        fast: fast,
        slow: slow,
        qty: qty
      ]
    }
  end

  defp meanrev_spec(opts, ticker, qty) do
    window = Keyword.get(opts, :window, 20)
    entry = Keyword.get(opts, :entry, 2.0)

    {MeanReversion,
      [
        name:  :"meanrev_#{window}",
        ticker: ticker,
        window: window,
        entry: entry,
        exit: 0.0,
        qty: qty
      ]
    }
  end
end

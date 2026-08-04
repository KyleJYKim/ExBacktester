defmodule ExBacktester.Runner do
  @moduledoc """
  Orchestrates a single backtest: load data, start strategies, wire teh Recorder, replay, then print the metrics table.

  ## The one ordering rule that matters

  The Recorder samples each strategy's equity when it receives a bar, and it must sample "after" teh strategies have traded on that same bar.
  The DataFeed dispatches to subscribers in the order they subscribed, so the Recorder has to subscribe 'last'.
  `run/2` enforces this by starting all strategies (and waiting for each to finish subscribing) before it calls `Recorder.track/1`, which triggers the Recorder's own subscription path.

  Get this backwards and every equity sample is off by one bar -- a textbook silent bug,
  which is why the ordering is spelled out here rather than left to chance.
  """

  alias ExBacktester.{DataFeed, Broker, Recorder, Metrics, Data.CSV, StrategySupervisor}

  @doc """
  Run a backtest.

    - `csv_path`  : path to an OHLCV CSV
    - `ticker`    : ticker symbol to tag the bars with
    - `specs`     : list of `{module, opts}` strategy child specs

  Returns a list of `%{name, ...metrics...}` maps and also prints a table.
  """
  def run(csv_path, ticker, specs) do
    Recorder.reset()
    bars = CSV.load!(csv_path, ticker)
    :ok = DataFeed.load(bars)

    names = Enum.map(specs, fn {module, opts} ->
      {:ok, _pid} = DynamicSupervisor.start_child(StrategySupervisor, {module, opts})
      name = Keyword.fetch!(opts, :name)
      # Sync barrier: block until this strategy's handle_continue has run and it has subscribed.
      # Guarantees subscribe order.
      _ = module.trades(name)
      name
    end)

    # Recorder subscribes last, so it samples equity after strategies trade.
    Enum.each(names, &Recorder.track/1)
    _ = Recorder.equity_curve(hd(names))

    {:ok, _n} = DataFeed.run()

    results = Enum.map(names, &summarise/1)
    print_table(results, length(bars))
    results
  end

  defp summarise(name) do
    curve = Recorder.equity_curve(name)
    account = Broker.account(name)

    %{
      name: name,
      trades: length(account.trades),
      final_equity: List.last(curve) || Broker.starting_cash(),
      total_return: Metrics.total_return(curve),
      sharpe: Metrics.sharpe(curve),
      max_drawdown: Metrics.max_drawdown(curve)
    }
  end

  defp print_table(results, n_bars) do
    IO.puts("\n#{n_bars} bars | starting cash #{fmt_money(Broker.starting_cash())}\n")

    IO.puts(
      String.pad_trailing("strategy", 20) <>
      String.pad_leading("trades", 8) <>
      String.pad_leading("final_eq", 14) <>
      String.pad_leading("return", 10) <>
      String.pad_leading("sharpe", 9) <>
      String.pad_leading("max dd", 9)
    )

    IO.puts(String.duplicate("-", 70))

    Enum.each(results, fn r ->
      IO.puts(
        String.pad_trailing(to_string(r.name), 20) <>
        String.pad_leading(to_string(r.trades), 8) <>
        String.pad_leading(fmt_money(r.final_equity), 14) <>
        String.pad_leading(fmt_pct(r.total_return), 10) <>
        String.pad_leading(fmt(r.sharpe), 9) <>
        String.pad_leading(fmt_pct(r.max_drawdown), 9)
      )
    end)

    IO.puts("")
  end

  defp fmt_money(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp fmt_pct(x), do: :erlang.float_to_binary(x * 100.0, decimals: 2) <> "%"
end

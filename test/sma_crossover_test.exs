defmodule ExBacktester.Strategy.SmaCrossoverTest do
  @moduledoc """
  Signal-logic tests. The two things most likely to be silently wrong in a
  crossover strategy are (a) trading before the slow window has filled and
  (b) trading on the *state* `fast > slow` rather than on the *transition*
  into it. Both are pinned here.
  """

  use ExUnit.Case, async: false

  alias ExBacktester.{Bar, DataFeed, Broker, StrategySupervisor}
  alias ExBacktester.Strategy.SmaCrossover

  @ticker "TEST"

  defp bars(closes) do
    closes
    |> Enum.with_index()
    |> Enum.map(fn {close, i} ->
      %Bar{
        ticker: @ticker,
        date: Date.add(~D[2024-01-01], i),
        open: close,
        high: close,
        low: close,
        close: close,
        volume: 1_000
      }
    end)
  end

  defp run(closes, opts) do
    name = :"sma_#{System.unique_integer([:positive])}"

    :ok = DataFeed.load(bars(closes))

    {:ok, pid} =
      DynamicSupervisor.start_child(
        StrategySupervisor,
        {SmaCrossover, Keyword.merge([name: name, ticker: @ticker], opts)}
      )

    # Sync barrier: handle_continue/2 is guaranteed to run before any other
    # message, so this call cannot be answered until the strategy has
    # subscribed. Cheaper and more reliable than sleeping.
    _ = SmaCrossover.trades(name)

    {:ok, _} = DataFeed.run()
    trades = SmaCrossover.trades(name)
    DynamicSupervisor.terminate_child(StrategySupervisor, pid)
    trades
  end

  test "does not trade before the slow window is full" do
    # 5 rising bars, slow window of 10: never enough data to form a signal.
    trades = run([1.0, 2.0, 3.0, 4.0, 5.0], fast: 2, slow: 10, qty: 1)
    assert trades == []
  end

  test "does not trade on the first full window, only on a later crossing" do
    # Monotonic rise: fast is above slow from the moment the window fills
    # and never crosses back. The first observation establishes the trend,
    # it must not be treated as a crossing.
    closes = Enum.map(1..30, &(100.0 + &1))
    trades = run(closes, fast: 3, slow: 5, qty: 1)
    assert trades == []
  end

  test "buys when fast crosses above slow, and only once per crossing" do
    # Fall, then a sustained rise: exactly one down -> up transition.
    closes = Enum.map(1..20, &(120.0 - &1)) ++ Enum.map(1..20, &(100.0 + &1))
    trades = run(closes, fast: 3, slow: 5, qty: 1)

    assert [%{side: :buy}] = trades
  end

  test "round trip: buys on the up-cross and sells on the down-cross" do
    closes =
      Enum.map(1..20, &(120.0 - &1)) ++
        Enum.map(1..20, &(100.0 + &1)) ++
        Enum.map(1..20, &(120.0 - &1))

    trades = run(closes, fast: 3, slow: 5, qty: 1)

    assert [%{side: :buy}, %{side: :sell}] = trades
  end

  test "a rejected order does not crash the strategy" do
    # qty far beyond starting cash: every buy is rejected, but the run
    # must still complete and the process must stay alive.
    closes = Enum.map(1..20, &(120.0 - &1)) ++ Enum.map(1..20, &(100.0 + &1))
    trades = run(closes, fast: 3, slow: 5, qty: 10_000_000)

    assert trades == []
  end

  test "starting cash is untouched when no signal fires" do
    name = :"sma_#{System.unique_integer([:positive])}"
    :ok = DataFeed.load(bars([1.0, 2.0, 3.0]))

    {:ok, pid} =
      DynamicSupervisor.start_child(
        StrategySupervisor,
        {SmaCrossover, name: name, ticker: @ticker, fast: 2, slow: 10, qty: 1}
      )

    _ = SmaCrossover.trades(name)
    {:ok, _} = DataFeed.run()
    assert Broker.account(name).cash == Broker.starting_cash()
    DynamicSupervisor.terminate_child(StrategySupervisor, pid)
  end
end

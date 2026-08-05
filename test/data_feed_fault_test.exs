defmodule ExBacktester.DataFeedFaultTest do
  @moduledoc """
  The OTP payload of the project: a strategy that crashes mid-run must not take the DataFeed (or the other strategies) down with it.
  The feed isolates each dispatch, drops the dead subscriber, and finishes the run.
  """

  use ExUnit.Case, async: false

  alias ExBacktester.{DataFeed, Bar, StrategySupervisor}

  # A minimal strategy that raises when it sees a close above a threshold.
  defmodule Crasher do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))

    def ping(name), do: GenServer.call(name, :ping)

    def init(opts), do: {:ok, opts, {:continue, :sub}}

    def handle_continue(:sub, state) do
      DataFeed.subscribe(self())
      {:noreply, state}
    end

    def handle_call(:ping, _from, state), do: {:reply, :ok, state}

    def handle_call({:bar, bar}, _from, state) do
      if bar.close > state.crash_above, do: raise("deliberate crash on #{bar.date}")
      {:reply, :ok, state}
    end
  end

  # A survivor that just counts bars, so we can prove it saw the whole run.
  defmodule Counter do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))

    def count(name), do: GenServer.call(name, :count)

    def init(opts), do: {:ok, Map.put(opts, :count, 0), {:continue, :sub}}

    def handle_continue(:sub, state) do
      DataFeed.subscribe(self())
      {:noreply, state}
    end

    def handle_call(:count, _from, state), do: {:reply, state.count, state}

    def handle_call({:bar, _bar}, _from, state), do: {:reply, :ok, %{state | count: state.count + 1}}
  end

  defp rising_bars(n) do
    for i <- 1..n do
      close = 100.0 + i

      %Bar{
        ticker: "X",
        date: Date.add(~D[2024-01-01], i),
        open: close,
        high: close,
        low: close,
        close: close,
        volume: 1
      }
    end
  end

  test "the feed survives a strategy that crashes mid-run" do
    feed_before = Process.whereis(DataFeed)

    :ok = DataFeed.load(rising_bars(10))

    {:ok, _} =
      DynamicSupervisor.start_child(
        StrategySupervisor,
        {Crasher, name: :fault_crasher, crash_above: 105.0}
      )

    _ = Crasher.ping(:fault_crasher)

    # A run whose only subscriber crashes still completes, and the feed is the same process afterwards
    # (it did not die and get restarted).
    assert {:ok, 10} = DataFeed.run()
    assert Process.whereis(DataFeed) == feed_before
  end

  test "a crashing strategy does not stop other strategies from finishing the run" do
    :ok = DataFeed.load(rising_bars(10))

    {:ok, _} =
      DynamicSupervisor.start_child(
        StrategySupervisor,
        {Crasher, name: :fault_crasher2, crash_above: 105.0}
      )

    {:ok, _} = DynamicSupervisor.start_child(StrategySupervisor, {Counter, name: :fault_counter})

    _ = Crasher.ping(:fault_crasher2)
    _ = Counter.count(:fault_counter)

    assert {:ok, 10} = DataFeed.run()

    # The counter subscribed after the crasher, yet still saw all 10 bars:
    # the crasher's failure on bar 6 did not abort the dispatch loop.
    assert Counter.count(:fault_counter) == 10
  end
end

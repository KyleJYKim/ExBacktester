defmodule ExBacktester.Recorder do
  @moduledoc """
  Records what happened during a run so the metrics can be computed at the end.
  Two things per strategy:
    - the equity curve: one snapshot of total account value per bar,
      which is what drawdown and Sharpe are computed from;
    - the trade log: every fill, for reporting trade counts.

  ## why the equity curve is sampled here and not in the Broker?

  The Broker knows cash and positions but is asked about them on demand; it does not keep a time series.
  The Recorder's job is precisely to turn those point-in-time answers into a series, one sample per bar.
  Keeping that concern out of the Broker keeps the Broker about "money now" and the Recorder about "money over time" -- two different responsibilities, two processes.

  ## How a snapshot is triggered?

  The Recorder subscribes to the DataFeed like a strategy does, so it receives every bar.
  But it must sample equity "after" the strategies have traded on that bar, not before.
  The DataFeed guarantees this by dispatching to subscribers in insertion order and the run wiring registers the Recorder "last" (see `Runner`).
  On each bar the Recorder asks the Broker for the current equity of every registered strategy and appends it.

  """

  use GenServer

  alias ExBacktester.Broker

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a strategy name to be sampled each bar."
  @spec track(atom()) :: :ok
  def track(strategy), do: GenServer.call(__MODULE__, {:track, strategy})

  @doc "The equity curve for a strategy, oldest first."
  @spec equity_curve(atom()) :: [float()]
  def equity_curve(strategy), do: GenServer.call(__MODULE__, {:equity_curve, strategy})

  @doc "Reset all recoreded state (between runs in the same VM)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Server callbacks

  @impl true
  def init(:ok) do
    # No subscription at boot: the DataFeed may not be registered yet, and there is noting to record until a run starts.
    # Subscribe lazily on the first `track/1` call, by which point the whole tree is up and the run is being wired.
    # `subscribed?` makes that idempotent across strategies.
    {:ok, %{tracked: [], curves: %{}, subscribed?: false}}
  end

  @impl true
  def handle_call({:track, strategy}, _from, state) do
    state = ensure_subscribed(state)

    state = state
      |> update_in([:tracked], &Enum.uniq([strategy | &1]))
      |> put_in([:curves, strategy], [])

    {:reply, :ok, state}
  end

  def handle_call({:equity_curve, strategy}, _from, state) do
    {:reply, Enum.reverse(Map.get(state.curves, strategy, [])), state}
  end

  def handle_call(:reset, _from, state) do
    # Keep the subscription (the process is still subscribed to the feed); only clear recorded data.
    {:reply, :ok, %{tracked: [], curves: %{}, subscribed?: state.subscribed?}}
  end

  # Bars arrive as calls, same protocol as strategies.
  # Sample equity for every tracked strategy and append to its curve (newest first).
  def handle_call({:bar, _bar}, _from, state) do
    curves = Enum.reduce(state.tracked, state.curves, fn strategy, acc ->
      equity = Broker.equity(strategy)
      Map.update(acc, strategy, [equity], &[equity | &1])
    end)

    {:reply, :ok, %{state | curves: curves}}
  end

  defp ensure_subscribed(%{subscribed?: true} = state), do: state

  defp ensure_subscribed(state) do
    :ok = ExBacktester.DataFeed.subscribe((self()))
    %{state | subscribed?: true}
  end
end

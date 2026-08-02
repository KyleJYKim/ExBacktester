defmodule ExBacktester.Strategy.SmaCrossover do
  @moduledoc """
  Simple moving average crossover — the "hello world" of systematic trading.

  Keep two rolling windows of closing prices, a fast one and a slow one.
  When the fast average crosses **above** the slow one, that is read as
  momentum turning up: go long. When it crosses **below**, exit.

  Only the *crossing* is a signal, not the state. `fast > slow` is true for
  long stretches; buying on every one of those bars would just accumulate
  position endlessly. So the strategy compares the current relationship to
  the previous one and acts only on the transition. That is what
  `state.trend` tracks.

  ## Rolling windows in process state

  Each window is a list of the last N closes, newest first, truncated with
  `Enum.take/2`. This is a legitimately good fit for GenServer state:
  it is small, it is owned by exactly one process, and it evolves strictly
  forward in time. No ETS, no Agent, no persistence needed.

  Until the slow window has filled up (N bars), there is no valid average
  and the strategy simply does nothing. Getting that warm-up right matters
  more than it looks — a strategy that trades on a half-filled window is
  trading on a different indicator than the one you think you wrote.

  ## Options

    * `:name`   — registered name, also the Broker account key (required)
    * `:ticker` — instrument to trade (default `"SAMPLE"`)
    * `:fast`   — fast window length (default 10)
    * `:slow`   — slow window length (default 30)
    * `:qty`    — shares per order (default 100)
  """

  use GenServer
  require Logger

  alias ExBacktester.{Broker, DataFeed}

  # ── Client API ──────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc "Trades executed by this strategy, oldest first."
  def trades(name), do: GenServer.call(name, :trades)

  # ── Server callbacks ────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      name: Map.fetch!(opts, :name),    # `fetch!/2` mandates `:name` option
      ticker: Map.get(opts, :ticker, "SAMPLE"),
      fast_len: Map.get(opts, :fast, 10),
      slow_len: Map.get(opts, :slow, 30),
      qty: Map.get(opts, :qty, 100),
      closes: [],
      trend: nil,
      trades: []
    }

    {:ok, state, {:continue, :register}}
  end

  @impl true
  def handle_continue(:register, state) do
    :ok = Broker.open_account(state.name)
    :ok = DataFeed.subscribe(self())
    {:noreply, state}
  end

  @impl true
  def handle_call({:bar, bar}, _from, state) do
    state =
      state
      |> push_close(bar.close)
      |> maybe_trade(bar)

    {:reply, :ok, state}
  end

  def handle_call(:trades, _from, state) do
    {:reply, Enum.reverse(state.trades), state}
  end

  # ── Internals ───────────────────────────────────────────────

  defp push_close(state, close) do
    # newest first; never keep more than the slow window needs
    %{state | closes: [close | state.closes] |> Enum.take(state.slow_len)}
  end

  defp maybe_trade(state, bar) do
    # No trading until the slow window is full — see moduledoc.
    if length(state.closes) < state.slow_len do
      state
    else
      fast = state.closes |> Enum.take(state.fast_len) |> mean()
      slow = mean(state.closes)
      trend = if fast > slow, do: :up, else: :down  # Golden or Death Cross

      state
      |> act_on_crossing(state.trend, trend, bar)
      |> Map.put(:trend, trend)
    end
  end

  # First full window: establish the trend, do not trade on it.
  defp act_on_crossing(state, nil, _trend, _bar), do: state
  # No crossing.
  defp act_on_crossing(state, same, same, _bar), do: state

  defp act_on_crossing(state, :down, :up, bar) do
    submit(state, :buy, bar)
  end

  defp act_on_crossing(state, :up, :down, bar) do
    submit(state, :sell, bar)
  end

  defp submit(state, side, bar) do
    case Broker.order(state.name, side, state.ticker, state.qty) do
      {:ok, fill} ->
        Logger.info(
          "#{state.name} #{side} #{fill.qty} #{fill.ticker} " <>
            "@ #{Float.round(fill.price, 2)} on #{fill.date}"
        )

        %{state | trades: [fill | state.trades]}

      {:error, reason} ->
        # Normal in a backtest (no cash, nothing to sell). Log and carry on;
        # a rejected order must not crash the strategy.
        Logger.debug("#{state.name} #{side} rejected on #{bar.date}: #{reason}")
        state
    end
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end

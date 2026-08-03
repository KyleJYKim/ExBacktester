defmodule ExBacktester.Strategy.MeanReversion do
  @moduledoc """
  Z-score mean reversion -- teh counterpart to trend-following.

  The bet is the opposite of the crossover's: when price falls far "below" its recent average, it is "too cheap" and expected to revert up, so buy;
  when it climbs back to teh average, the reversion has played out, so exit.

  "Too cheap" is made precise with a z-score over a rolling window:
      z = (price - mean(window)) / stddev(window)
  Enter long when `z <= -entry` (default -2.0: two standard deviations below the mean).
  Exit when `z >= exit` (default 0.0: back to the mean).
  A single position at a time, long-only, matching the Broker's rules.

  ## Same window machinery, different signal

  The rolling-window state is identical in shape to SmaCrossover's -- alist of recent closes, newest first, truncated to the window length, no trading until it is full.
  What differs is only the function computed over the window (a z-score instead of two averages) and the entry/exit condition.
  That symmetry is the point: once you have one GenServer strategy, a second is a new decision rule over the same skeleton, which is exactly how a real strategy framework grows.

  ## Options

    - `:name`   : registered name / Broker account key (required)
    - `:ticker` : instrument (default `"SAMPLE"`)
    - `:window` : lookback length (default 20)
    - `:entry`  : entry z-threshold, positive number (default 2.0)
    - `:exit`   : exit z-threshold (default 0.0)
    - `:qty`    : shares per order (default 100)
  """

  use GenServer
  require Logger

  alias ExBacktester.{Broker, DataFeed}

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  def trades(name), do: GenServer.call(name, :trades)

  # Server callbacks

  @impl true
  def init(opts) do
    state = %{
      name: Map.fetch!(opts, :name),
      ticker: Map.get(opts, :ticker, "SAMPLE"),
      window: Map.get(opts, :window, 20),
      entry: Map.get(opts, :entry, 2.0),
      exit: Map.get(opts, :exit, 0.0),
      qty: Map.get(opts, :qty, 100),
      closes: [],
      holding: false,
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
    state = state
      |> push_close(bar.close)
      |> maybe_trade(bar)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:trades, _from, state) do
    {:reply, Enum.reverse(state.trades), state}
  end

  # Internals

  defp push_close(state, close) do
    %{state | closes: [close | state.closes] |> Enum.take(state.window)}
  end

  defp maybe_trade(state, bar) do
    if length(state.closes) < state.window do
      state
    else
      case zscore(state.closes, bar.close) do
        # No dispersion in the window: no meaningful signal.
        nil -> state
        z -> decide(state, z, bar)
      end
    end
  end

  # Flat: enter long when price is far below the mean.
  defp decide(%{holding: false} = state, z, bar) when z <= 0 do
    if z <= -state.entry, do: submit(state, :buy, bar), else: state
  end

  defp decide(%{holding: false} = state, _z, _bar), do: state

  # Holding: exit when price has reverted to (or above) the mean.
  defp decide(%{holding: true} = state, z, bar) do
    if z >= state.exit, do: submit(state, :sell, bar), else: state
  end

  defp submit(state, side, bar) do
    case Broker.order(state.name, side, state.ticker, state.qty) do
      {:ok, fill} ->
        Logger.info(
          "#{state.name} #{side} #{fill.qty} #{fill.ticker} " <>
            "@ #{Float.round(fill.price, 2)} on #{fill.date}"
        )

        %{state | holding: side == :buy, trades: [fill | state.trades]}

      {:error, reason} ->
        Logger.debug("#{state.name} #{side} rejected on #{bar.date}: #{reason}")
        state
    end
  end

  defp zscore(closes, price) do
    m = mean(closes)
    sd = stddev(closes, m)
    if sd == 0.0, do: nil, else: (price - m) / sd
  end

  defp mean(xs), do: Enum.sum(xs). / length(xs)

  defp stddev(xs, m) do
    variance = Enum.reduce(xs, 0.0, fn x, acc -> acc + (x - m) * (x - m) end) / length(xs)
    :math.sqrt(variance)
  end
end

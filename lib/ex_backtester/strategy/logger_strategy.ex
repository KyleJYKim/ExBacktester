defmodule ExBacktester.Strategy.LoggerStrategy do
  @moduledoc """
  The simplest possible strategy: it subscribes to the DataFeed and logs
  every bar it receives. It exists purely to prove the week-1 milestone:
  "strategies log every bar they receive, in order."

  In week 2 this file becomes the template for SmaCrossover — same shape,
  real indicator state instead of a counter.

  ## Note the `handle_continue` pattern

  Subscribing happens in `handle_continue/2`, not directly in `init/1`.
  `init` blocks the supervisor that is starting this process, so calling
  out to another GenServer from `init` is a habit that eventually bites
  (slow init → slow supervision tree startup; circular calls → deadlock).
  `{:continue, ...}` runs immediately after init returns, before any
  other message is processed — the idiomatic place for post-init work.
  """

  use GenServer
  require Logger

  # ── Client API ──────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{name: name}, name: name)
  end

  # ── Server callbacks ────────────────────────────────────────

  @impl true
  def init(%{name: name}) do
    {:ok, %{name: name, bars_seen: 0}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    :ok = ExBacktester.DataFeed.subscribe(self())
    {:noreply, state}
  end

  @impl true
  def handle_call({:bar, bar}, _from, state) do
    Logger.info(
      "#{inspect(state.name)} bar ##{state.bars_seen + 1} " <>
        "#{bar.date} close=#{bar.close}"
    )

    {:reply, :ok, %{state | bars_seen: state.bars_seen + 1}}
  end
end

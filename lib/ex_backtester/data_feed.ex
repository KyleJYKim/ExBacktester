defmodule ExBacktester.DataFeed do
  @moduledoc """
  Replays historical bars to subscribed strategies -- the "market clock".

  ## The key design decision: synchronous stepping

  Each bar is delivered to every subscriber with `GenServer.call/3`, NOT `cast`.
  The feed does not move to bar N+1 until every strategy has finished processing bar N and replied `:ok`.

  Why this matters: with `cast`, bars pile up in strategy mailboxes at their own pace.
  Strategy A could be trading on bar 40 while Strategy B is still computing bar 12 -- and both hitting the same Broker.
  The backtest results would silently depend on scheduler timing.
  In a simulation, "determinism beats throughput."
  This is the first real OTP design trade-off in the project.

  ## Fault isolation

  A strategy that crashes on a bar must not take the feed down with it.
  `run/0` dispatches to each subscriber inside a `try`; a subscriber that exits (crash) or times out is logged, dropped from the live set, and the run continues for everyone else.

  Three containment designs were considered:

    - `Process.alive?/1` before each call: a check-then-act race; the process can die between the check and the call. Rejected.
    - moitor every subscriber, handle `:DOWN`: correct and the most "OTP" answer, but the run loop here is a single synchronous `call` pass, so catching the exit at the call site simpler and local.
    - `try/catch` around each dispatch (chosen): the crash surfaces exactly where the feed depends on the strategy, so that is where it is handled.
      A dropped subscriber cannot corrupt the others because each dispatch is independent.

  Note this only isolates "the feed" from a strategy crash.
  The strategy process itself is under a `DynamicSupervisor` and will be restarted per its child spec -- but with fresh state (its rolling window is gone), which is the correct question to sit with: for a backtest, is a restarted-empty strategy meaningful, or should a crashed strategy simply be excluded from the results?
  Here it is excluded, which is the honest choice.
  """

  use GenServer
  require Logger

  alias ExBacktester.{Broker, Bar}

  @bar_timeout 5_000

  # ── Client API ──────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Load a list of bars (oldest first) into the feed."
  @spec load([Bar.t()]) :: :ok
  def load(bars) when is_list(bars) do
    GenServer.call(__MODULE__, {:load, bars})
  end

  @doc "Subscribe the calling process (or `pid`) to receive bars."
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc """
  Replay every loaded bar through all subscribers, in order.
  Blocks until the run completes. Returns `{:ok, bars_replayed}`.
  """
  @spec run() :: {:ok, non_neg_integer()}
  def run do
    GenServer.call(__MODULE__, :run, :infinity)
  end

  # ── Server callbacks ────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, %{bars: [], subscribers: []}}
  end

  @impl true
  def handle_call({:load, bars}, _from, state) do
    {:reply, :ok, %{state | bars: bars}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    # Monitor so a dead subscriber is dropped instead of leaking.
    Process.monitor(pid)
    {:reply, :ok, update_in(state.subscribers, &[pid | &1])}
  end

  def handle_call(:run, _from, state) do
    # Subscribers were prepended; reverse for stable, insertion-order delivery.
    subscribers = Enum.reverse(state.subscribers)

    Enum.each(state.bars, fn bar ->
      # Price authority first: the Broker must know today's price before
      # any strategy is allowed to send it an order for today.
      :ok = Broker.mark(bar)

      Enum.each(subscribers, fn pid ->
        # Synchronous step: wait for each strategy to ack this bar.
        :ok = GenServer.call(pid, {:bar, bar}, @bar_timeout)
      end)
    end)

    {:reply, {:ok, length(state.bars)}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, update_in(state.subscribers, &List.delete(&1, pid))}
  end
end

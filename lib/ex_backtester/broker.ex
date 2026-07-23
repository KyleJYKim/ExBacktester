defmodule ExBacktester.Broker do
  @moduledoc """
  The single source of truth for money. Strategies never mutate cash or
  positions themselves — every change flows through this one process,
  serialised by its mailbox. That is the OTP answer to "where does shared
  mutable state live?"

  ## Fill model (v0.1)

  Orders fill at the **close of the bar the strategy is currently seeing**,
  with a flat fee. That is a deliberate simplification with a known bias,
  and you should understand it rather than forget it:

  A strategy decides *because of* today's close, then trades *at* today's
  close. In reality you cannot see a closing price and also trade at it —
  this is a mild form of **lookahead bias**, and it flatters results.
  The honest alternative is filling at the *next* bar's open (signal today,
  execute tomorrow morning), which is what a real system does. That is a
  good week-4 exercise once the pipeline works. Note it in the README
  rather than silently shipping optimistic numbers.

  ## Why the Broker learns prices from the DataFeed, not from strategies

  `mark/1` is called by the DataFeed *before* each bar is dispatched to
  strategies. So when a strategy sends an order, the Broker already knows
  the current price independently. If instead strategies passed their own
  price along with the order, a buggy strategy could fill at any price it
  liked and the backtest would quietly lie. Keep price authority on the
  Broker side.

  ## Accounts

  One account per strategy, keyed by the strategy's registered name, so
  two strategies on the same feed have independent cash and positions and
  can be compared fairly.
  """

  use GenServer

  alias ExBacktester.Bar

  @starting_cash 100_000.0
  @fee_rate 0.001

  @type side :: :buy | :sell
  @type account :: %{
          cash: float(),
          positions: %{String.t() => non_neg_integer()},
          trades: [map()]
        }

  # ── Client API ──────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Open an account for a strategy. Idempotent."
  @spec open_account(atom()) :: :ok
  def open_account(strategy) do
    GenServer.call(__MODULE__, {:open_account, strategy})
  end

  @doc """
  Record the current bar as the market price. Called by the DataFeed
  before dispatching the bar to strategies.
  """
  @spec mark(Bar.t()) :: :ok
  def mark(%Bar{} = bar), do: GenServer.call(__MODULE__, {:mark, bar})

  @doc """
  Submit an order. Returns `{:ok, fill}` or `{:error, reason}`.

  Rejects rather than raises: a strategy trying to buy more than it can
  afford is a normal event in a backtest, not a crash.
  """
  @spec order(atom(), side(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def order(strategy, side, ticker, qty)
      when side in [:buy, :sell] and is_integer(qty) and qty > 0 do
    GenServer.call(__MODULE__, {:order, strategy, side, ticker, qty})
  end

  @doc "Current account state for a strategy."
  @spec account(atom()) :: account() | nil
  def account(strategy), do: GenServer.call(__MODULE__, {:account, strategy})

  @doc "Cash + positions marked at the last known price."
  @spec equity(atom()) :: float() | nil
  def equity(strategy), do: GenServer.call(__MODULE__, {:equity, strategy})

  @doc "The starting cash every account is opened with."
  def starting_cash, do: @starting_cash

  # ── Server callbacks ────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, %{accounts: %{}, prices: %{}, date: nil}}
  end

  @impl true
  def handle_call({:open_account, strategy}, _from, state) do
    accounts =
      Map.put_new(state.accounts, strategy, %{
        cash: @starting_cash,
        positions: %{},
        trades: []
      })

    {:reply, :ok, %{state | accounts: accounts}}
  end

  def handle_call({:mark, bar}, _from, state) do
    {:reply, :ok,
     %{state | prices: Map.put(state.prices, bar.ticker, bar.close), date: bar.date}}
  end

  def handle_call({:order, strategy, side, ticker, qty}, _from, state) do
    with {:ok, account} <- fetch_account(state, strategy),
         {:ok, price} <- fetch_price(state, ticker),
         {:ok, account, fill} <- execute(account, side, ticker, qty, price, state.date) do
      accounts = Map.put(state.accounts, strategy, account)
      {:reply, {:ok, fill}, %{state | accounts: accounts}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:account, strategy}, _from, state) do
    {:reply, Map.get(state.accounts, strategy), state}
  end

  def handle_call({:equity, strategy}, _from, state) do
    case fetch_account(state, strategy) do
      {:ok, account} -> {:reply, mark_to_market(account, state.prices), state}
      {:error, _} -> {:reply, nil, state}
    end
  end

  # ── Internals ───────────────────────────────────────────────

  defp fetch_account(state, strategy) do
    case Map.fetch(state.accounts, strategy) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, :no_account}
    end
  end

  defp fetch_price(state, ticker) do
    case Map.fetch(state.prices, ticker) do
      {:ok, price} -> {:ok, price}
      :error -> {:error, :no_price}
    end
  end

  defp execute(account, :buy, ticker, qty, price, date) do
    gross = qty * price
    fee = gross * @fee_rate
    total = gross + fee

    if total > account.cash do
      {:error, :insufficient_cash}
    else
      fill = fill(date, :buy, ticker, qty, price, fee)

      account = %{
        account
        | cash: account.cash - total,
          positions: Map.update(account.positions, ticker, qty, &(&1 + qty)),
          trades: [fill | account.trades]
      }

      {:ok, account, fill}
    end
  end

  defp execute(account, :sell, ticker, qty, price, date) do
    held = Map.get(account.positions, ticker, 0)

    # v0.1 rule: long-only, no shorting. Rejecting here keeps the equity
    # calculation honest and the scope closed.
    if qty > held do
      {:error, :insufficient_position}
    else
      gross = qty * price
      fee = gross * @fee_rate
      fill = fill(date, :sell, ticker, qty, price, fee)

      account = %{
        account
        | cash: account.cash + gross - fee,
          positions: Map.put(account.positions, ticker, held - qty),
          trades: [fill | account.trades]
      }

      {:ok, account, fill}
    end
  end

  defp fill(date, side, ticker, qty, price, fee) do
    %{date: date, side: side, ticker: ticker, qty: qty, price: price, fee: fee}
  end

  defp mark_to_market(account, prices) do
    Enum.reduce(account.positions, account.cash, fn {ticker, qty}, acc ->
      acc + qty * Map.get(prices, ticker, 0.0)
    end)
  end
end

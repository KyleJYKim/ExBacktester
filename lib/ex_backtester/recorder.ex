defmodule ExBacktester.Recorder do
  @moduledoc """
  WEEK 3 — currently a stub so the supervision tree is complete from day one.

  Will subscribe to fills from the Broker and record, per strategy:

    * every trade (date, side, ticker, qty, price, fee)
    * the daily equity value (cash + mark-to-market positions)

  At the end of a run it computes exactly three metrics (v0.1 rule —
  no more than these three):

    * total P&L and return %
    * Sharpe ratio: mean(daily returns) / std(daily returns) * sqrt(252)
    * max drawdown: largest peak-to-trough drop in the equity curve
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # week 3: %{trades: [], equity_curve: []} per strategy
    {:ok, %{}}
  end
end

defmodule ExBacktester.Broker do
  @moduledoc """
  WEEK 2 — currently a stub so the supervision tree is complete from day one.

  Will become the single source of truth for money-state:

    * receives `{:buy, ticker, qty}` / `{:sell, ticker, qty}` from strategies
    * fills at the current bar's close price
    * applies a flat fee (0.1%)
    * tracks cash + positions PER STRATEGY
    * replies with the fill so the strategy knows what happened
    * emits each fill to the Recorder

  Design rule to hold on to: strategies never mutate money-state
  themselves. All fills flow through this one process. That is the OTP
  answer to "where does shared mutable state live?" — in exactly one
  process, guarded by its mailbox.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # week 2: %{accounts: %{strategy_name => %{cash: ..., positions: %{}}}}
    {:ok, %{}}
  end
end

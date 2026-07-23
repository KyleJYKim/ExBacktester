# Week 2 — the Broker gets real

**Milestone reached:** one full backtest run. Bars in, trades out, plausible final cash.
500 bars, 21 trades, equity marked to market with an open position at the end.

## Commit plan (5 commits, all pushed)

5. Add `ticker` to `Bar`, thread it through `CSV.load!/2` — commit "bar carries its ticker".
   The Broker needs to know what it is pricing.
6. Replace the `Broker` stub with the real one — commit "broker: accounts, fills, fees".
   Check in iex: open an account, `mark/1` a bar, `order/4`, inspect `account/1`.
7. `DataFeed` calls `Broker.mark(bar)` before dispatching — commit "feed marks broker first".
   One line, but it is the whole price-authority design (see Broker moduledoc).
8. Add `strategy/sma_crossover.ex`, delete `logger_strategy.ex` — commit "sma crossover".
9. Add `test/broker_test.exs` + `test/sma_crossover_test.exs` — commit "tests for fill math
   and signal logic". `mix test` → 14 passing.

## Two design decisions worth arguing about

**1. Fill price = today's close.** The strategy decides *because of* today's close and
trades *at* today's close, which is mild lookahead bias and flatters results. The honest
model is filling at the next bar's open (signal today, execute tomorrow). Left as-is for
v0.1, documented in the Broker moduledoc, and worth changing in week 4 if time allows.
Either way it goes in the README — never ship optimistic numbers silently.

**2. Price authority lives on the Broker, not the strategy.** Strategies send
`{:buy, ticker, qty}` with no price. If they passed their own price, a buggy strategy
could fill wherever it liked and the backtest would quietly lie. The DataFeed marks the
Broker before dispatching each bar, so the Broker always knows the price independently.

## The race you should look at

`DynamicSupervisor.start_child/2` returns once `init/1` returns — but `handle_continue/2`,
where the strategy subscribes, has not run yet. Calling `DataFeed.run()` immediately can
therefore start the replay before anyone is subscribed. The tests caught this: two came
back with zero trades.

The fix is not `Process.sleep/1`. Because `handle_continue/2` is guaranteed to run before
any other message, *any* `GenServer.call` to the strategy blocks until subscription is
done. So a throwaway `SmaCrossover.trades(name)` is a correct sync barrier. Same lesson as
week 1, now with teeth.

## Week 3 preview
`Recorder` becomes real (equity curve + trade log), second strategy (mean reversion,
z-score over a 20-day window), the three metrics, and the deliberate crash test: kill a
strategy mid-run and watch it take the DataFeed down, then decide how to contain it.

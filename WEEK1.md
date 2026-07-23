# ex_backtester — Week 1

**Milestone:** two strategies log every bar they receive, in order, from a CSV replay.
**Definition of done for v0.1 (do not renegotiate):** 2 strategies, daily bars from CSV,
P&L + Sharpe + max drawdown in a CLI table, survives a crashing strategy, README with
one chart. Tagged v0.1 + ElixirForum write-up. Everything else goes in FUTURE.md.

## Out of scope for v0.1
No live trading. No broker/API integration. No web UI. No 3rd strategy.
No intraday data. No parameter optimization. No ML.

## Commit plan (each one small, each one pushed)

1. `mix new ex_backtester --sup` — commit "initial mix project". Day one. Twenty minutes.
2. Add `bar.ex` + `data/csv.ex` + `priv/data/sample.csv` — commit "bar struct and CSV loader".
   Check in iex: `ExBacktester.Data.CSV.load!("priv/data/sample.csv") |> length()`
3. Add `broker.ex` + `recorder.ex` stubs, update `application.ex` with the full
   supervision tree — commit "supervision tree skeleton".
   Check: `mix run --no-halt` starts clean; `:observer.start()` shows the tree (if you
   have wx) or `Supervisor.which_children(ExBacktester.Supervisor)` in iex.
4. Add `data_feed.ex` + `strategy/logger_strategy.ex` — commit "data feed with
   synchronous stepping". Check: `mix run demo.exs` → interleaved a/b logs, bars in order.

That's week 1. Four commits, all public.

## Things to actually understand before week 2 (not just paste)

- Why `GenServer.call` and not `cast` in DataFeed.run/0 (determinism vs throughput —
  read the moduledoc).
- Why LoggerStrategy subscribes in `handle_continue` and not `init`.
- What happens right now if a strategy crashes mid-run (nothing is protecting the
  DataFeed — that's deliberate; you break it on purpose in week 3).

## Week 2 preview
Broker becomes real (orders, fills, fees, per-strategy accounts), LoggerStrategy is
copied into SmaCrossover with two rolling windows (10/30). Milestone: one full
backtest, trades printed, final cash plausible.

alias ExBacktester.{DataFeed, Broker, Data.CSV, StrategySupervisor}
alias ExBacktester.Strategy.SmaCrossover

ticker = "SAMPLE"
bars = CSV.load!("priv/data/sample.csv", ticker)
IO.puts("Loaded #{length(bars)} bars: #{hd(bars).date} -> #{List.last(bars).date}\n")

:ok = DataFeed.load(bars)

{:ok, _} =
  DynamicSupervisor.start_child(
    StrategySupervisor,
    {SmaCrossover, name: :sma_10_30, ticker: ticker, fast: 10, slow: 30, qty: 100}
  )

# Sync barrier rather than a sleep: handle_continue/2 runs before any other
# message, so this call cannot return until the strategy has subscribed.
_ = SmaCrossover.trades(:sma_10_30)

{:ok, n} = DataFeed.run()
IO.puts("\nReplayed #{n} bars.\n")

acct = Broker.account(:sma_10_30)
equity = Broker.equity(:sma_10_30)
start = Broker.starting_cash()

IO.puts("trades:    #{length(acct.trades)}")
IO.puts("cash:      #{:erlang.float_to_binary(acct.cash, decimals: 2)}")
IO.puts("positions: #{inspect(acct.positions)}")
IO.puts("equity:    #{:erlang.float_to_binary(equity, decimals: 2)}")
IO.puts("return:    #{:erlang.float_to_binary((equity - start) / start * 100, decimals: 2)}%")

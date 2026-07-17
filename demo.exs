alias ExBacktester.{DataFeed, Data.CSV, StrategySupervisor}
alias ExBacktester.Strategy.LoggerStrategy

bars = CSV.load!("priv/data/sample.csv")
IO.puts("Loaded #{length(bars)} bars, #{hd(bars).date} -> #{List.last(bars).date}")

:ok = DataFeed.load(bars)

{:ok, _} = DynamicSupervisor.start_child(StrategySupervisor, {LoggerStrategy, name: :strategy_a})
{:ok, _} = DynamicSupervisor.start_child(StrategySupervisor, {LoggerStrategy, name: :strategy_b})
Process.sleep(50)

{:ok, n} = DataFeed.run()
IO.puts("Run complete: #{n} bars replayed")

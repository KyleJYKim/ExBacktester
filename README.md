# README.md

# Why does the Datafeed mark the Broker before dispatching the bar?
Because the Broker is the price authority, and it can only be authoritative if it already know the price when an order arrives.
A strategy's order is just `{:buy, "SAMPLE", 100}` — no price attached. So the Broker has to look one up from its own state, and `mark/1` is what puts it there. The dispatch that follows is what eventually causes the order, so marking has to come first.

### What breaks if you swap them.
Suppose the mark happened after the dispatch loop. On bar N, a strategy sends a buy; the Broker looks up `state.prices` and finds bar N-1's close still sitting there, before bar N hasn't been marked yet. Every fill in the entire run executes one bar late. Nothing crashes, no test fails on its own, the equity curve still looks plausible — it's just wrong. That's the same species of bug as the dataset one in your thesis: a quiet off-by-one that changes conclusion.
Worse on the first bar specifically: `state.prices` is empty, so `fetch_price/2` returns `{:error, :no_price}`, the order is rejected, and the strategy logs it at debug level and moves on. You'd never see it.
There's second thing riding along. `mark/1` also stamps the data:
	`%{state | prices: Map.put(state.prices, bar.ticker, bar.close), date: bar.date}`
Fills are recorded with `state.date`, so marking late would also date every trade to the previous bar.

## Why not just let the strategy send the price?
That was the alternative, and it's the one to reject deliberately. `Broker.order(name, :buy, ticker, qty, price)` would make the strategy the price authority — and a strategy with a bug in its window arithmetic. ould then fill at any number it computed, including one that never appeared in the data. The backtest would report profits that no market could have given you, without a single error. Keeping price on the Broker means the worst a broken strategy can do is trade at the worng time; it can never trade at a fake price.

# Why does the DataFeed use call instead of cast to dispatch bars?
Because a backtest must be deterministic, and `cast` give that away for free performance you don't need.
`GenServer.cast` is fire-and-forget: the message lands in the mailbox and th caller moves on immediately. `GenServer.call` sends and then blocks until the receiver replies. Here's what the loop does:
	`
	Enum.filter(live, fn pid ->
		:ok = GenServer.call(pid, {:bar, bar}, @bar_timeout)
		true
	end)
	`
Bar N is not sent to anyone until every subscriber has finished processing bar N-1.

### What breaks with cast.
The DataFeed would blast all bars into every strategy's mailbox in microseconds, then return. The strategies would drain those mailboxes at whatever pace the BEAM scheduler gives them. Now picture two strategies sharing one Broker:
 - `sma_10_30` is on bar 300, sends a buy.
 - `meanrev_20` is still on bar 49, sends a sell.
 - The Broker has `prices` set to whatever the DataFeed marked most recently — bar 500, say, since the feed already finished.
Both fill at teh wrong price, and which wrong price depends on scheduler timing. Run the backtest twice and get two different answers. That's fatal for the thing a backtester exists to do: you can't tell whether a change to your strategy improved results or whether you just got a different interleaving.
The marking problem makes it concrete. `Broker.mark(bar)` and the strategy's `order` are only correctly paired if the strategy processes bar N while N is the marked price. `cast` destroys that pairing entirely — the feed races ahead marking bar after bar while strategies lag behind.

### Why `call` is the natural fix.
The reply isn't used for information — the strategies just return `:ok`. It's used purely as a barrier. The reply means "I'm done with this bar," and that's exactly the synchronization the simulation needs. Using a request/reply primitive to get ordering rather than data is a legitimate and common OTP pattern.

What you give up. Throughput. Everything runs on one logical timeline, so two strategies don't process bars in parallel even though they could. For 500 bars that's milliseconds — irrelevant. If you ever wanted real parallelism you'd need a different design: dispatch with `cast`, then a per-bar barrier where the feed waits for N acknowledgements before advancing. That gets you parallel strategy computation with preserved bar ordering — more complex, and worth exactly nothing at this scale.

The connection to the crash test. `call` is also what made the fragility visible. A `cast` to a dying process silently succeeds — the message vanishes and the feed never notices. Because `call` links the feed's fate to the strategy's reply, a crashing strategy propagated its exit into the feed and killed it. That's why the fix had to be an explicit `try/catch`: `call` surfaces failures rather than swallowing them.

# What does a strategy do when it receives a bar?
Three things, in a fixed order: record the price, compute the indicator, decide whether the transition warrants an order. The whole thing is one `handle_call`.
`
    def handle_call({bar, bar}, _from, state) do
        state = state |> push_close(bar.close) |> maybe_trade(bar)
        {:reply, :ok, state}
    end
`
That `:reply, :ok` is the barrier -- it's the strategy saying "done with this bar, send the next one."

## Step1 -- push the close into the rolling window.
`
    defp push_close(state, close) do
        %{state | closes: [close | state.closes] |> Enum.take(state.slow_len)}
    end
`
Prepend, then truncate. Newest first, never longer than the slowest indicator needs.
Prepending is O(1) in Elixir; appending would be O(n). And truncating to `slow_len` means memory is bounded no matter how long the run -- a 500-bar or 500,000-bar backtest holds the same 30 floats.

## Step2 -- refuse to act until the window is full.
`
    if length(state.closes) < state,.slow_len do
        state
    else
        fast = state.closes |> Enum.take(state.fast_len) |> mean()
        slow = mean(state.closes)
        trend = if fast > slow, do: :up, else: :down
        ...
`
This warm-up guard matters more than it looks. A 30-day average computed over 7 days is a 7-day average. Trading during warm-up means your first trades come from a signal you never designed, and the results silently blend two strategies.

## Step3 -- act on the transition, not the state.
This is the part worth internalizing, because it's where most naive strategy code is wrong:
`
    defp act_on_crossing(state, nil, _trend, _bar), do: state   # first full window
    defp act_on_crossing(state, same, same, _bar), do: state    # no crossing
    defp act_on_crossing(state, :down, :up, bar), do: submit(state, :buy, bar)
    defp act_on_crossing(state, :up, :down, bar), do: submit(state, :sell, bar)
`
`fast > slow` stays true for long stretches -- maybe sixty bars in a row. Buying on every bar where it's true would pile up sixty positions. What you want is the "moment" it becomes true. so the strategy stores yesterday's answer in `state.trend` and compares it to today's; only a genuine `:down -> :up` or `:up -> :down` produces an order.

The `nil` clause is the subtle one. On the very first full window there's no previous trend to compare against, so the strategy records the trend and does nothing. Skip that clause and you'd fire a trade on bar 30 of every run purely because "no previous state" happened to differ from "up" -- a phantom signal with no market meaning. There's a test pinning exactly this (`does not trade on the first full window`).

This is also the cleanest illustration of why GenServer state fits here: the strategy is a small state machine whose transitions depend on what it saw last. That memory has to live somewhere, and a process that owns it exclusively is the right home.

## Step4 -- submit, and survive rejection.
`
    case Broker.order(state.name, side, state.ticker, state.qty) do
        {:ok, fill} -> %{state | trades: [fill | state.trades]}
        {:error, reason} ->
            Logger.debug("...rejected...")
            state
    end
`
The strategy asks; it doesn't assume. A rejection (no cash, nothing to sell) is a normal backtest event, not an exceptino -- it's logged and the run continues. Note also that the strategy never touches cash or positions; it only appends the returned fill to its own local log for reporting.

MeanReversion is the same skeleton. Same `push_close`, same warm-up guard, same submit-and-tolerate-rejection. Only two things differ: the function over the window (a z-score instead of two means) and the decision rule (`holding` boolean instead of `trend`). That symmetry is the payoff -- once you have one strategy process, a second one is a new decision rule dropped into an identical shape. That's how a real strategy framework grows, and it's what would make a third strategy a twenty-minute job rather than a redesign.

# How does the Broker fill or reject an order?
It's a four-stage gauntlet, and any stage can turn the order into an `{:error, reason}` that flows back to the strategy as a normal reply rather than a crash:
`
    def handle call ({:order, strategy, side, ticker, qty}, _from , state) do
        with {:ok, account} <- fetch_account(state, strategy),
             {:ok, price} <- fetch_price(state, ticker),
             {:ok, account, fill} <- execute(account, side, ticker, qty, price, state.date)
            accounts = Map.put(state.accounts, strategy, account)
            {:reply, {:ok, fill}, %{state | accounts: accounts}}
        else
            {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
`
Read the `else` branch carefully: it replies with the error and returns `state` -- the original, untouched. That's the key property. A rejected order cannot partially mutate anything, because the new account map is only written into state on the success path. There's no way to half-fill.

## Stage0 -- the guard, before the message is even sent.
`
    def order(strategy, side, ticker, qty) when side in [:buy, :sell] and is_integer(qty) and qty > 0 do
`
A guard on the client function, so it runs in the caller's process. `Broker.order(:sma, :buy, "X", -50) raises a `FunctionsClauseError` in the strategy, not in the Broker. Nonsense arguments are a programming error, and they die at the call site rather than traveling into the money-owning process.

## Stage1 and 2 -- account and price must exist.
`:no_account` means the strategy never called `open_account/1`. `:no_price` means nothing has been marked for that ticker yet -- the exact failure that would happen on every single bar if you dispatched before marking.

## Stage2 -- the arithmetic, which differs by side.
Buying:
`
    gross = qty * price
    fee   = gross * @fee_rate
    total = gross + fee
    
    if total > account.cash do
        {:error, :insufficient_cash}
    else
        ...cash: account.cash - total
        positions: Map.update(account.positions, ticker, qty, &(&1 + qty))
`
The fee is added to what you pay. Selling inverts it:
`
    cash: account.cash + gross - fee
`
The fee is subtracted from what you receive. Fees always work against you on both sides -- that asymmetry is the whole point, and there's test pinning it: buy and sell at the same price and you lose exactly two fees. if that test ever passes with zero loss, fees have silently stopped applying.
The affordability check use `total`, not `gross`. Check against `gross` and an order that costs exactly your remaining cash would push you fractionally negative once the fee lands.
Selling has its own gate:
`
    held = Map.get(account.positions, ticker, 0)
    if qty > held do
        {:error, :insufficient_position}
`
This is what enforces long-only, no shoring. Without it, `positions` would go negative, and `mark_to_market` would happily multiply a negative quantity by a price and report equity that doesn't correspond to any real portfolio. One guard closes both the scope and the correctness hole.

### Why reject instead of raise.
A strategy running out of cash is an ordinary event in a backtest -- it happens constantly and means nothing is broken. If it raised, the exit would propagate through the synchronous `call` chain into the DataFeed and kill the run. Returning `{:error, reason}` lets the strategy log at debug and carry on. The rule: reserve exceptions for programmer errors (the stage-0 guard), and use tagged tuples for domain outcomes.

## Two things the Broker deliberately refuses to do.
It never accepts a price from the caller -- it looks one up from `state.prices`, which is why the mark-before-dispatch ordering matters. And it never keeps a time series; it answers "what is the money now" and leaves "money over time" to the Recorder. Two responsibilities, two process.
That's also why every fill flows through this one mailbox: `handle_call` is serialized by definition, so there is no lock, no transaction, and no interleaving to reason about. Two strategies ordering on the same bar are simply two messages in a queue. Shared mutable state without any of the usual concurrency pain.

# Why must the Recorder subscribe last?
Because the DataFeed dispatches to subscribers in subscription order, and the Recorder measures a consequence of what the strategies just did.
The order is set here:
`
    def handle_call({:subscribe, pid}, _from , state) do
        Process.monitor(pid)
        {:reply, :ok, update_in(state.subscribers, &[pid | &1])}
    end
`
Prepend on subscribe, then in `run`:
`
    subscribers = Enum.reverse(state.subscribers)
`
Reversed back to insertion order, and `Enum.filter` walks that list in order. So within one bar, subscriber 1 fully finishes before subscriber 2 is called -- that's the synchronous stepping again.
Now that the Recorder does on each bar:
`
    def handle_call({:bar, _bar}, _from, state) do
        curves =
            Enum.reduce(state.tracked, state.curves, fn strategy, acc ->
                equity = Broker.equity(strategy)
                Map.update(acc, strategy, [equity], &[equity | &1])
            end)
        ...
`
It ignores the bar's contents entirely -- `bar`. It's using the bar purely as a tick, a signal to go ask the Broker "what is this strategy worth right now?" So the answer depends entirely on whether the strategies have already traded on this bar.

### What goes wrong if it subscribes first.
On bar N the Recorder samples equity, then the strategies trade on bar N. So the curve records pos-bar-(N - 1) equity at index N. Every sample is shifted one bar late. And it compounds: `total_return` reads the last point, which would now be the equity before the final bar's trades; drawdown and Sharpe are computed over a series that never quite matches the trades that produced it. Nothing crashes. The numbers just don't correspond to the run.
Note the sample is off in two ways, because `Broker.equity/` marks positions at `state.prices` -- which the DataFeed already updated for bar N before any dispatch. So an early Recorder would combine bar N's price with bar N-1's positions. A mixture of two moments in time, reported as one.

### How the ordering is enforced.
Not by hoping -- the `Runner` does it explicitly:
`
    names =
        Enum.map(specs, fn {module, opts} ->
            {:ok, _pid} = DynamicSupervisor.start_child(StrategySupervisor, {module, opts})
            name = Keyword.fetch!(opts, :name)
            _ = module.trades(name)     # sync barrier
            name
        end)

    names |> Enum.each(&Recorder.track/1)
    _ = names |> hd() |> Recorder.equity_curve()
`
Each strategy is started and confirmed subscribed (via the `handle_continue` barrier) before the next line runs. Only then does `Recorder.track/1` fire, which triggers the Recorder's lazy `ensure_subscribed`. The throwaway `equity_curve` call is the same barrier trick applied to the Recorder.
Without those barriers, "start A, then B, then track" wouldn't actually guarantee subscribe order at all -- `start_child` returns before `handle_continue` runs, so B could subscribe before A. The barriers are what turn code order into subscription oder.

### Why the Recorder is a subscriber at all.
It could have been simpler: have the DataFeed explicitly call `Recorder.snapshot()` after the dispatch loop. That's arguably clearer, and worth considering as a refactor -- it makes the ordering structural rather than conventional. The cost is that the DataFeed would then know about the Recorder specifically, instead of holding an. opaque list of pids. Right now the feed has no idea what its subscribers are, which is exactly why the crash test could plug in a throwaway `Counter` module. Coupling versus an ordering convention -- a real trade-off.



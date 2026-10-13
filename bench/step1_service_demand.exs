# Step 1: measure the Broker's service demand before predicting anything.
#
#   mix run bench/step1_service_demand.exs
#
# (a) Pure service time S: Broker.handle_call/3 as a plain function.
# (b) R(1): one closed-loop client. With N = 1 nobody ever queues, so
#     R(1) = D, the full per-request cost including message passing.
# (c) Sanity check: the interactive response time law N = X (R + Z).

alias ExBacktester.Bench

n = 10
service_time_acc = 1..n |>
  Enum.reduce(0, fn i, acc ->
    service_time = Bench.service_time(1_000_000)
    IO.puts("S (pure service time), trial #{i}: #{Float.round(service_time, 3)} µs")
    acc + service_time
  end)

IO.puts("S (average): #{Float.round(service_time_acc / n, 3)} µs")
IO.puts("")

for z <- [0, 1] do
  result = Bench.run(1, z_ms: z, measure_ms: 3000)
  # To check if the number of users in the system is exactly 1 that is supposed here.
  sys_user_num = result.x_per_s * (result.r_us + result.z_us) / 1_000_000

  IO.puts(
    "N=1  Z_set=#{z}ms -> X=#{round(result.x_per_s)}/s R=#{Float.round(result.r_us, 2)} µs " <>
    "Z_measured=#{Float.round(result.z_us, 1)} µs  mailbox=#{Float.round(result.mailbox_mean, 3)} " <>
    "X(R+Z)=#{Float.round(sys_user_num, 3)}"
  )
end

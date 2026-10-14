# Step 2: sweep the number of clients N and compare against the model.
#
#   mix run bench/step2_sweep.exs
#
# 1. Measure D_b = R(1) with Z = 0 (ho0t, no queueing) and teh real Z.
# 2. PREDICT before measuring: knee N*, ceiling 1/D_b.
# 3. Sweep N; for each run record X, R, Z, mailbox length Q_w, and derive
#    W = Q_w / X (Little's law on the mailbox) and D_eff = R - W.
# 4. Write bench/results/sweep.csv for plotting (bench/plot_sweep.py).

alias ExBacktester.Bench
alias ExBacktester.Bench.Model

Logger.configure(level: :warning)

ns = [1,2,5,10,20,50,100,200,400,700,1000,1500,2000,3000,4000]
z_set_ms = 1

IO.puts("schedulers online: #{System.schedulers_online()} (OTP #{System.otp_release()})\n")

# 1. calibrate
hot = Bench.run(1, z_ms: 0, measure_ms: 2000)
cal = Bench.run(1, z_ms: z_set_ms, measure_ms: 2000)
d_b = hot.r_us
z = cal.z_us

IO.puts("calibration: D_b = R(1, z=0) = #{Float.ropund(d_b, 2)} µs Z measured = #{Float.round(z, 1)} µs")

# 2. predict
IO.puts("prediction: N* = (D + Z) / D_b = #{round(Model.knee([d_b], z))}")
IO.puts("            X_max = 1 / D_b    = #{round(1_000_000 / d_b)} orders/s\n")

# 3. sweep
header = "n,x_per_s,r_us,z_us,mailbox_mean,w_us,d_eff_us,law_n,x_bound,r_bound,x_mva,r_mva"

IO.puts(
  String.pad_leading("N", 5) <>
  String.pad_leading("X/s", 10) <>
  String.pad_leading("R µs", 10) <>
  String.pad_leading("Q_w", 8) <>
  String.pad_leading("W µs", 9) <>
  String.pad_leading("R-W µs", 9) <>
  String.pad_leading("X(R+Z)", 9) <>
  String.pad_leading("X bound", 10) <>
  String.pad_leading("X mva", 10)
)

mva = Model.mva(Enum.max(ns), [d_b], z)

rows =
  for n <- ns do
    r = Bench.run(n, z_ms: z_set_ms, measure_ms: 3000)
    x_s = r.x_per_s / 1_000_000
    w = if x_s > 0, do: r.mailbox_mean / x_s, else: 0.0
    law_n = x_s * (r.r_us + r.z_us)
    b = Model.bounds(n, [d_b], z)
    m = Enum.at(mva, n - 1)

    IO.puts(
      String.pad_leading("#{n}", 5) <>
      String.pad_leading("#{round(r.x_per_s)}", 10) <>
      String.pad_leading("#{Float.round(r.r_us, 2)}", 10) <>
      String.pad_leading("#{Float.round(r.mailbox_mean, 2)}", 8) <>
      String.pad_leading("#{Float.round(w, 2)}", 9) <>
      String.pad_leading("#{Float.round(r.r_us - w, 2)}", 9) <>
      String.pad_leading("#{Float.round(law_n, 1)}", 9) <>
      String.pad_leading("#{round(b.x_upper * 1_000_000)}", 10) <>
      String.pad_leading("#{round(m.x * 1_000_000)}", 10)
    )

    Enum.join(
      [
        n, r.x_per_s,
        r.r_us,
        r.z_us,
        r.mailbox_mean,
        w,
        r.r_us - w,
        law_n,
        b.x_upper * 1_000_000,
        b.r_lower,
        m.x * 1_000_000,
        m.r
      ],
      ","
    )
  end

File.mkdir_p!("bench/results")
File.write!("bench/results/sweep.csv", Enum.join([header | rows], "\n") <> "\n")

file.write!(
  "bench/results/calibration.txt",
  "schedulers=#{System.schedulers_online()}\nd_b_us=#{d_b}\nz_us=#{z}\n"
)

IO.puts("\nwrote bench/results/sweep.csv")

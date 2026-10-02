# SMART-EVP: technical guide

This document explains how SMART-EVP works: the model, the files, the security design, the
experiments and the dashboard. It is meant for anyone who wants to read, run or extend the project.
Headline results are in the main [README](../README.md).

---

## 1. The big picture

### The problem
An ambulance loses time at traffic lights. Every red light, and every queue of cars waiting at
that light, slows it down. In an emergency, those seconds matter.

### The idea
**EVP (Emergency Vehicle Preemption)** lets the ambulance tell the traffic light it is coming.
The light then changes early so the ambulance finds a green light and an empty road.

### What the project adds
1. The ambulance sends **cryptographically signed messages**, so nobody can fake an ambulance
   and take over a junction.
2. A **corridor** of 3 junctions that are warned early (pre-notification).
3. A **queue-aware, just-in-time trigger** (adaptive mode) that starts preemption only when needed.
4. A **patient vs empty ambulance** priority rule, with a commit rule so a nearly-crossing
   ambulance is not cut off.
5. **Recovery logic** after preemption so cross traffic is not left stuck.
6. **Safety checks and fault injection** to prove the system fails safe.
7. A **web dashboard** to replay runs and compare results.

### What it is NOT
It is a **simulation in MATLAB**, with no hardware. The "patient on board" check is a simulated
priority flag in a registry, not sensor detection. ESP32, MQTT and e-mail alerts are not implemented.

---

## 2. Vocabulary

| Term | Meaning |
|---|---|
| Junction | One signalised intersection. There are 3 along the corridor. |
| Road A | The main road the patient ambulance drives along. |
| Road B | The cross road at each junction. |
| Stop line | The position where cars must stop. Distances are measured to it. |
| Phase | Which road currently has green. |
| Preemption | The junction overrides its normal timing to serve the ambulance. |
| ETA | Estimated time of arrival at the stop line = distance / speed. |
| Queue | Cars waiting at a red light. |
| Saturation flow | How fast a queue drains on green (0.5 veh/s = 1800 veh/h). |
| Delay (ambulance) | Actual travel time minus the free-flow travel time (no lights at all). |
| Monte Carlo | Repeating a random simulation many times with different seeds. |
| Seed | A number that fixes the random numbers, so a run is repeatable. |
| 95% CI | The range that likely contains the true mean (explained in section 8). |
| HMAC | A signature made with a shared secret key (explained in section 7). |
| Replay attack | Re-sending a real, captured message. |

---

## 3. How the pieces fit together

```
config_params.m   (all numbers)
        |
        v
run_simulation.m  (the engine)  <---- sign_message / verify_message / message_payload / hmac_sha256
        |
        +--> run_experiments / export_results / run_volume_sweep /
        |    run_two_ambulance_experiments      (many runs + statistics via summary_stats)
        +--> run_fault_tests / test_security     (safety and security verification)
        +--> demo_single_run / demo_two_ambulances   (plots)
        +--> export_feed / export_results   (JSON files)
                         |
                         v
                  dashboard.html  (JSON files are loaded in the browser)
```

The engine is one function. Everything else either feeds it settings, calls it many times, or
turns its output into tables, plots or JSON.

---

## 4. File-by-file reference

### Core
| File | What it does |
|---|---|
| `config_params.m` | Every tunable number in one place: timing, geometry, traffic, ambulance physics, radio, keys, priorities. Change values here only. |
| `run_simulation.m` | The engine. One call simulates 240 s in 0.5 s steps for one scenario and returns a results struct with metrics and a full trace. |

### Security
| File | What it does |
|---|---|
| `hmac_sha256.m` | Computes HMAC-SHA256 as a hex string using MATLAB's built-in Java crypto. |
| `message_payload.m` | Builds the exact text that is signed: `id|seq|ts|x|v|dir`. The `src` field is not signed (it is only evaluation metadata saying who really sent it). |
| `sign_message.m` | Makes a message (id, sequence number, timestamp, position, speed, road) and attaches the signature. |
| `verify_message.m` | The junction's checks, in order: registered ID, valid signature, fresh timestamp, not a replay. Returns ok or the rejection reason. |
| `test_security.m` | 10 unit tests of the above, including the known HMAC test vector. It uses `assert`, so it stops with an error if any test fails. |

### Experiments and statistics
| File | What it does |
|---|---|
| `summary_stats.m` | Returns mean, 95% confidence half-width, standard deviation and count. Uses `tinv` if available, otherwise an approximation. |
| `run_experiments.m` | A script: 50 Monte Carlo runs of fixed, EVP local and EVP corridor, plus the four attack scenarios. |
| `run_two_ambulance_experiments.m` | Monte Carlo with a patient and an empty ambulance: fixed vs EVP both prioritised vs EVP patient only. Saves a CSV and a figure. |
| `run_volume_sweep.m` | Fixed vs EVP fixed trigger vs EVP adaptive at traffic volumes 0.5x, 1x, 1.5x, 1.8x. This is the test of the adaptive-trigger claim. |
| `export_results.m` | Runs the Monte Carlo, the two-ambulance study and the volume sweep, and writes `results_summary.json` for the dashboard charts. |

### Verification
| File | What it does |
|---|---|
| `run_fault_tests.m` | Fault injection: 18 scenarios times N seeds, each checked against pass/fail rules and safety invariants. Writes `results/fault_tests.csv`. (The README says 16 scenarios, but the file defines 18.) |

### Launchers and demos
| File | What it does |
|---|---|
| `main.m` | Quick launcher: fixed, EVP local, EVP corridor on seed 42, prints the delays. |
| `run_all.m` | The master pipeline. Runs everything and exports every JSON file. This is the main entry point. |
| `demo_single_run.m` | Time-space diagram: fixed-time vs EVP corridor. Picks a "typical" seed whose fixed delay is closest to the mean. |
| `demo_two_ambulances.m` | Time-space diagrams for the patient (road A) and the empty ambulance (road B at junction 2). |

### Dashboard export
| File | What it does |
|---|---|
| `export_feed.m` | Writes one run as a JSON feed: metadata plus one frame per time step. This is the current exporter. |
| `export_dashboard_data.m` | An older copy of `export_feed.m`. It lacks the phase-direction, operator, trigger-mode and second-ambulance fields. Delete it to avoid confusion. |

### Documentation and web
| File | What it does |
|---|---|
| `dashboard.html` | The playback and analysis dashboard (section 10). |

---

## 5. Inside the engine (`run_simulation.m`)

### 5.1 Inputs
```matlab
res = run_simulation(cfg, mode, seed, opts)
```
* `mode`: `'fixed'` (normal timing, no priority) or `'evp'` (priority logic on).
* `seed`: fixes the random numbers.
* `opts` (all optional): `range` ('local' or 'corridor'), `security` (true by default),
  `twoAmb`, `leadMode` ('fixed' or 'adaptive'), `attack` ('badsig', 'unregistered', 'replay',
  'stale'), `attackJunction`, `attackWindow`, `blackout`, `stuckAt`, `operator`.

### 5.2 The seed trick (paired comparison)
Traffic arrivals use their own random stream seeded by `seed`. Message loss uses separate streams
(`seed + 100000 + ...`). So the same seed produces the **same cars arriving at the same moments**
in fixed-time and EVP. The only thing that differs is the control strategy. That makes the
comparison fair: differences come from the strategy, not from luck.

### 5.3 The corridor
```
start x=0 ----300 m---- J1 ----400 m---- J2 ----400 m---- J3 ----200 m---- hospital (x=1300)
```
Free-flow time = 1300 m / 16.7 m/s, about 77.8 s. Ambulance delay = actual time minus that.
If the ambulance does not finish in 240 s, its trip is penalised (it counts the full horizon).

### 5.4 The signal state machine
Each junction is always in one of 8 states:

| # | State | Meaning |
|---|---|---|
| 1 | A green | Normal green for road A (30 s) |
| 2 | A yellow | 4 s |
| 3 | All red | 2 s |
| 4 | B green | Normal green for road B (25 s) |
| 5 | B yellow | 4 s |
| 6 | All red | 2 s |
| 7 | EV green (A) | Emergency green for road A |
| 8 | EV green (B) | Emergency green for road B |

Normal cycle: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 1, total 67 s. There is an `allowed` table of legal
transitions. If the code ever makes an illegal jump, `illegalTransitions` goes up and the fault
tests fail. **Preemption never skips yellow or all-red** when switching roads. That is the
safety backbone.

Each junction starts at a random point in the cycle (so junctions are not artificially in sync).

### 5.5 What happens every 0.5 s
The loop runs these steps in order:

1. **Arrivals.** Each road at each junction gets a car with probability `lambda * dt` per step
   (0.12 * 0.5 = 6%). A car arriving on green into an empty queue just drives through. Otherwise it joins the queue.
2. **Queue discharge.** On green (after 2 s of start-up lost time), the queue drains at the
   saturation flow of 0.5 veh/s, using an accumulator so fractional cars carry over.
3. **Messages.** Every `msgPeriod` (1 s) each active ambulance signs a message and sends it to every junction ahead
   of it that is within radio range (250 m local, 1000 m corridor). Each message is lost with
   probability 5%. This step also injects attacker messages when an attack is configured.
4. **Junctions process messages.** If security is on, `verify_message` runs. Rejected messages are
   counted by reason. Accepted ones update the junction's view of the ambulance. A junction
   **starts** a request only if the ambulance is approaching (distance shrinking) and the trigger rule says go.
   A stopped, waiting ambulance keeps its request alive.
5. **Release logic.** A preemption ends in one of three ways:
   * **exit**: the ambulance passed the stop line by 15 m (the normal way),
   * **dropout**: no valid message for 3 s (fail safe if radio dies),
   * **watchdog**: preemption has lasted over 60 s (fail safe if the ambulance is stuck).
6. **Arbitration.** If several ambulances want a junction, the winner is the highest priority
   (patient 2 beats empty 1), ties broken by earliest request. **Commit rule:** if an ambulance is
   within 50 m before the stop line (or just past it) and currently has green, it is not cut off.
   Losing ambulances accumulate `heldSeconds`.
7. **Operator commands.** Manual overrides (`cancel`, `force_A`, `force_B`, `release`) win over
   everything, but still pass through yellow and all-red.
8. **Signal controllers.** `step_signal` advances each state machine, using the arbitration result.
9. **Ambulance physics.** The ambulance accelerates to cruise speed but slows to 5 m/s through a
   discharging queue, brakes for red lights, and proceeds on yellow only if it cannot stop. Passing a
   red counts as a `redRun`. This should always be zero.

Every step is saved in a **trace** (position, speed, signal states, queues, engaged flags,
phase direction), which is what the dashboard replays.

### 5.6 The trigger: fixed vs adaptive
**Fixed trigger (conventional EVP):** start preempting when `ETA <= leadTime` (20 s). Simple, but
it can preempt too early and disrupt cross traffic for no benefit.

**Adaptive trigger (just-in-time):** the junction uses its own state.
* Road already green: do nothing unless that green would end before the ambulance arrives
  (green time left <= ETA + queue slowdown + 5 s margin).
* Road not green: start when `ETA <= time to reach green + time to flush the queue + 5 s margin`.
  Time to reach green is the rest of minimum green plus yellow plus all-red.

The aim is the same or lower ambulance delay with less cross-road disruption. `run_volume_sweep` tests it.

### 5.7 Recovery after preemption
After the ambulance passes, the junction does not just resume the old timing. It gives the starved
road a green sized to its queue:
```
recovery green = min(35 s, max(10 s, ceil(queue / 0.5) + 2 + 2))
```
`recoveryMean` measures how long the junctions take to get back to a queue of 2 cars or fewer.

---

## 6. The results struct: what each metric means

| Field | Meaning | Better is |
|---|---|---|
| `ambDelay` | Patient ambulance travel time minus free-flow time (s) | lower |
| `ambStops` | Number of times the ambulance came to a stop | lower |
| `delayA`, `delayB` | Average wait per car on road A or B (queue-seconds divided by arrivals) | lower |
| `maxQueue` | Longest queue seen anywhere | lower |
| `recoveryMean` | Average time for a junction to clear after preemption | lower |
| `preemptSeconds` | Total junction-seconds spent preempted | lower (less disruption) |
| `emptyDelay`, `heldSeconds` | Second ambulance delay and time it was held back | context |
| `accepted`, `rejects`, `lostMsgs` | Message accounting | n/a |
| `spoofedEngagements` | Times an **attacker** message triggered preemption | **must be 0** with security on |
| `conflicts` | Steps where both roads had green | **must be 0** |
| `illegalTransitions` | Illegal signal jumps | **must be 0** |
| `redRuns` | Ambulance crossings on red | **must be 0** |
| `maxSpeed` | Highest ambulance speed | must not exceed cruise |

The four "must be 0" rows are the **safety invariants**. EVP is only worth anything if the speed-up
does not cost safety.

---

## 7. Security, explained simply

### The threat
If a junction obeyed any radio message saying "ambulance coming", anyone could force green lights.

### HMAC-SHA256
Both ambulance and junction know a secret key. The ambulance computes
`signature = HMAC(key, "id|seq|ts|x|v|dir")` and sends message plus signature. The junction recomputes it.
If one character of the message changed, or the key was wrong, the signatures differ. An attacker without the key cannot produce a valid one.

### The four checks (in this order)
1. **Registered?** Is the ID in the registry? Else `unregistered`.
2. **Signature valid?** Compare signatures in constant time (so timing does not leak information). Else `bad_signature`.
3. **Fresh?** `|now - timestamp| <= 2 s`. Else `stale`.
4. **New?** Sequence number must be greater than the last accepted one from that ID **at that junction**. Else `replay`.

### The attacks tested
| Attack | What the attacker does | Which check stops it |
|---|---|---|
| `badsig` | Forges a message signed with a guessed key | signature |
| `unregistered` | Uses a fake ID `AMB-999` | registry |
| `replay` | Duplicates a real packet | sequence number |
| `stale` | Re-sends an old real message | timestamp |

### The control experiment
One fault test turns security **off** and runs the bad-signature attack. It must **succeed**
(`spoofedEngagements > 0`). That proves the attack is real and the defence is what stops it.

### Priority cannot be faked
The junction looks priority up in its **own registry** (`cfg.prio`) by verified ID. A vehicle cannot claim a higher priority in its message.

### What security does not cover
Shared symmetric demo keys, no key rotation, no hardware protection, no radio jamming, no
compromised ambulance unit, no compromised junction controller.

---

## 8. Statistics, explained simply

### Why many runs?
One run depends on random traffic. One lucky or unlucky seed proves nothing. So the experiments run 50 seeds per
strategy, which is **Monte Carlo**.

### Mean and 95% confidence interval
`summary_stats` returns the mean and a half-width:
```
CI = t * sd / sqrt(n)
```
Read it as: "mean +/- CI". With 50 runs the true average lies inside that range with about 95%
confidence. The bars on the dashboard charts ("whiskers") are this CI.

### How to read a comparison
* **Ranges far apart:** the difference is real.
* **Ranges overlapping:** a difference cannot be claimed from the plot alone. (A paired test on the same seeds would be stronger.)
* Always report **both** sides of the trade-off: EVP lowers ambulance delay but raises cross-road delay.
* Say "in this simulation", never "in the real world".

### The studies in the project
| Study | Question it answers |
|---|---|
| Fixed vs local vs corridor (50 runs) | Does EVP help, and does early notice help more? |
| Volume sweep | Does the adaptive trigger beat the fixed trigger as traffic grows? |
| Two ambulances | Does the empty ambulance get delayed, and does the patient stay protected? |
| Attack evaluation | Do all four attacks fail? |
| Fault injection | Does the system stay safe when things break? |

---

## 9. The 18 fault-injection scenarios

Each runs over several seeds (10 by default) and must satisfy its rule **and** the safety invariants.

| # | Scenario | What it proves |
|---|---|---|
| 1 | Normal EVP (corridor) | Every junction preempts, safely |
| 2 to 5 | Replay, bad signature, unregistered ID, stale message | Each attack is rejected, 0 spoofed engagements |
| 6 | Control: attack with security off | The attack works without security (validates the test) |
| 7 | Radio/GPS dropout (8 to 16 s) | Dropout release triggers, still safe |
| 8 | Blocked exit | Watchdog releases a stuck preemption |
| 9 | 50% packet loss | Still finishes safely |
| 10 | Two ambulances: conflict at J2 | Patient wins, empty is held, patient delay barely changes |
| 11 | Empty arrives first | Empty is pre-empted by the patient |
| 12 | Empty already committed | Commit rule protects it |
| 13 | Same road, follow | Two ambulances in a row |
| 14 | Empty gets no priority | Empty treated as ordinary traffic |
| 15 | Operator cancels preemption at J2 | Override works safely |
| 16 | Operator forces road B green at J1 | Override works safely |
| 17 | Adaptive trigger | Works and stays safe |
| 18 | Adaptive trigger plus two ambulances | Combined case |

---

## 10. The dashboard

### Running it
1. Run `run_all` in MATLAB. Expect it to take a while (hundreds of simulations plus fault tests).
2. Open `dashboard.html` in a browser.
3. Click **Load feeds** and select all the `.json` files in one go.

### How it recognises each file
It reads the shape of the data, not the file name:
* has `frames` and `meta`: a **simulation feed** (one scenario),
* has `attackType`: the **security log**,
* has `scenarios` and `metrics`: the **Monte Carlo results**.

### Pages
| Page | What is on it |
|---|---|
| Overview | Key numbers for the selected scenario, and a table comparing every scenario with fixed-time signals |
| Live corridor | Play/pause, speed, scrub bar, night mode, the animated corridor, junction cards, speed chart, event log |
| Analysis | Monte Carlo charts and the scenario comparison table (with CSV download) |
| Operator console | Builds the MATLAB command for manual overrides |
| Security log | Rejection counts and spoofed engagements for the exported attack run |

The top bar has the **Scenario** picker, **Load feeds** and **Print page**.
On the Live page: **Space** plays or pauses, **left/right arrows** jump 5 s.

### Important limits
* It **replays saved runs**. It cannot control a running simulation. The operator console only writes MATLAB code that is then run.
* The oncoming and cross-road cars in the animation are **decorative**. The real data is the ambulance, the signal states and the queue counts.
* The security page only shows the one attack exported by `run_all` (replay).

### JSON feed structure (for reference)
```
meta:   mode, ambDelay, ambStops, normalDelayB, maxQueue, acceptedMsgs,
        rejectedMsgs{...}, operator[], leadMode, (twoAmb, emptyDelay, heldSecondsEmpty)
frames: [ { time, ambulance{x,v}, junctions{state[], qA[], qB[], engaged[], pdir[]},
            (ambulance2{active,road,x,v}) }, ... ]   one per 0.5 s
```

---

## 11. How to run everything

| Goal | Command |
|---|---|
| Everything, including exports | `run_all` |
| Quick three-scenario check | `main` |
| Security unit tests only | `test_security` |
| Fault tests with 10 seeds | `run_fault_tests(10)` |
| One time-space plot | `demo_single_run` |
| Two-ambulance plots | `demo_two_ambulances` |
| Monte Carlo summary JSON | `export_results(50)` |
| One feed for the dashboard | `export_feed(res, 'feed_x.json')` |

Operator override example:
```matlab
opts = struct('range','corridor','twoAmb',true, ...
              'operator',[struct('t',30,'junction',2,'cmd','cancel')]);
res = run_simulation(cfg,'evp',7,opts);
export_feed(res,'feed_operator.json');
```

### Troubleshooting
* `struct2array` (used in `run_all.m` and `run_experiments.m`) may require a toolbox on some installs.
  If it errors, replace `sum(struct2array(x))` with `sum(cell2mat(struct2cell(x)))`.

---

## 11b. Results (50 Monte Carlo runs, mean +/- 95% CI, simulation only)

| Metric | Fixed-time | EVP local | EVP corridor |
|---|---|---|---|
| Ambulance delay (s) | 28.1 +/- 6.5 | 3.1 +/- 0.9 | 1.8 +/- 0.7 |
| Ambulance stops | 1.1 +/- 0.3 | 0 | 0 |
| Cross-road delay (s) | 19.6 +/- 0.8 | 22.2 +/- 0.8 | 22.5 +/- 0.8 |
| Main-road delay (s) | 14.7 +/- 0.5 | 13.7 +/- 0.5 | 13.4 +/- 0.4 |
| Max queue (veh) | 9.3 +/- 0.4 | 9.8 +/- 0.5 | 9.8 +/- 0.5 |

* EVP removes most of the ambulance delay and all stops. The cost is about 2.6 to 2.9 s more delay per vehicle on the cross road, and that increase is clear because the intervals do not overlap.
* Local and corridor ranges overlap slightly, so these plots alone do not show that corridor is better than local.
* Two ambulances: patient delay falls from 26.7 +/- 9.2 s to 1.9 +/- 1.0 s. Giving the empty ambulance priority holds it for 21.3 s on average.
* Security: a replay attack run produced 19 rejected messages and 0 spoofed engagements.

---

## 12. Limitations

* Simplified traffic: two-phase signals, random (Bernoulli) arrivals, one lane per approach, a fixed "bypass factor" for queues.
* Not calibrated with real traffic data, and not compared with SUMO or field data.
* One patient ambulance, plus at most one empty ambulance on one cross road.
* Idealised braking. If a light changes late, the ambulance is stopped instantly at the line.
* Security uses shared demo keys with no rotation.
* Results depend on the parameters in `config_params.m`.
* Dashboard is playback only.
* No ESP32, no MQTT, no e-mail alerts. The patient check is a simulated flag.

---

## 13. Design FAQ

**Why does the same seed matter?**
It makes traffic identical across strategies, so the comparison is paired and fair.

**Why 50 runs, and what is the CI?**
One run is random. 50 runs give a mean, and the 95% CI shows how uncertain that mean is.

**Why could someone not fake an ambulance?**
Messages are signed with HMAC-SHA256 using a secret key, and the junction also checks the ID registry, freshness and sequence number.

**What is the difference between a replay and a stale attack?**
Replay re-sends a fresh message that was already used (caught by the sequence number). Stale re-sends an old one (caught by the timestamp).

**Why a control test with security off?**
It proves the attack works without defences, so the defence is the thing that stops it.

**What happens if the radio dies mid-preemption?**
After 3 s with no valid message the junction releases (dropout release) and resumes normal operation safely.

**What if the ambulance gets stuck?**
The watchdog releases after 60 s of continuous preemption.

**How do two ambulances not collide at a junction?**
Arbitration picks one road at a time, with yellow and all-red between switches. The patient wins, unless the empty ambulance is already within 50 m of the line and on green.

**What is the downside of EVP?**
Cross traffic waits longer. That is why both ambulance delay and cross-road delay are reported, and why recovery logic exists.

**What makes the adaptive trigger different from conventional EVP?**
The hypothesis is that starting just in time gives similar ambulance delay with less cross-road disruption. The volume sweep (`run_volume_sweep`) is the test, and the confidence intervals decide whether it holds.

**Does it detect a patient?**
No. It uses a simulated priority registry (`cfg.prio`). Real detection would need hardware, which is out of scope.

**Why must conflicts, illegalTransitions and redRuns be zero?**
They are the safety invariants. A faster ambulance is worthless if it causes conflicting greens or red-light crossings.

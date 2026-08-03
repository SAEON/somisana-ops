# somisana-ops — operational workflow design

Design record for the `somisana-ops` repo: operational workflows for running CROCO,
WW3 and OpenDrift.

**Status — design complete, no code written yet.**

D1–D19 (§2) are settled. No blocking questions remain; §4 lists what is deferred to
implementation. §5 is the file-by-file skeleton, §6 the build order.

**▶ Next step: Phase 1 of §6** — `my_env.sh`, `lib/`, `combos_croco.txt`,
`.env.example`. Test by sourcing and printing the resolved banner for each of the 8
rows: confirm `FDAYS` (5 / 2.45) and `CLIM_FILE` (set / empty) derive correctly, and that
nothing leaks between rows.

**The one thing to keep in view throughout:** `latest/` is a contract downstream services
depend on (D7). Phase 4 must produce a `latest/` tree matching the current system's file
for file, diffed against the live archive, before anything else proceeds. Everything else
in this design is recoverable; breaking that contract breaks consumers silently.

**Reading order if you are picking this up cold:** §1 (why), then D4 + D7 + D11 (the three
decisions everything else hangs off), then §5.

---

## 1. Purpose and provenance

This repo hosts the *operational orchestration*. Model configuration files stay in their
own repos, assumed present on the run server:

| repo | role |
|---|---|
| `../somisana-croco` | CROCO configs + `cli.py` (bry/ini, tides, regridding, plots) |
| `../somisana-ww3` | WW3 configs + `cli.py` |
| `../somisana-opendrift` | OpenDrift configs + `cli.py` |
| `../somisana-download` | download CLI |

Two ancestors:

- **`../somisana-croco/.github/workflows`** — the existing operational system. Defines
  *what must be reproduced*. Everything is GitHub Actions YAML, which makes testing any
  single component in isolation hard. That is the problem being solved.
- **`../oceanmotion-models/ops`** — the design philosophy to adopt. A collection of bash
  scripts driven by a `my_env.sh` of defaults, each runnable standalone at a prompt.

**The goal:** reproduce what `somisana-croco/.github/workflows` does, built the way
`oceanmotion-models/ops` is built.

### What the existing system does per cycle

One 03:00 cron on the `mims3` self-hosted runner:

```
pull images → checkout → cleanup
  → prep_domain (rm -rf + copy configs + compile)     × 2 domains
  → downloads: GFS → SAWS (chained), MERCATOR (via saeonapps hop), HYCOM
  → make_tides                                        × 2 domains
  → run_all_domains(MERCATOR) then run_all_domains(HYCOM), each:
       make_bry_ini                                   × 2 domains
       run + postprocess, sequentially:
         sa_west/GFS → sa_southeast/GFS → sa_west/SAWS → sa_southeast/SAWS
                                          (SAWS legs gated on SAWS_OK)
```

Net: **8 run+postprocess pipelines** (2 domains × 2 OGCM × 2 BLK), 4 download streams,
2 tide files, 4 bry/ini files. `HDAYS=5`, `FDAYS=5` (2.45 for SAWS).

---

## 2. Settled decisions

### D1 — Leaf workflow is one combo; a parent calls it N times

One GitHub workflow per `(DOMAIN × OGCM × BLK)` combo, parameterised by
`workflow_call` / `workflow_dispatch` inputs. A higher-level workflow calls it 8 times.
Same shape as today's `run_all_domains.yml` → `run_croco.yml`.

**Not a matrix** — a failed leg kills its siblings (this was hit in practice; `fail-fast:
false` exists but matrix was rejected on other grounds too).

Workflow inputs are **optional with `default: ''`** and exported straight to the
environment. Because `${VAR:-default}` fires on unset *or empty*, an unspecified input
falls through to the `my_env.sh` default. Defaults therefore live in exactly one place
and cannot drift into YAML.

```yaml
on:
  workflow_call:
    inputs:
      DOMAIN:   {type: string, required: false, default: ''}
      OGCM:     {type: string, required: false, default: ''}
      BLK:      {type: string, required: false, default: ''}
      RUN_DATE: {type: string, required: false, default: ''}
  workflow_dispatch:   # same inputs — manual single-combo test from the UI
jobs:
  run:
    runs-on: mims3
    env:
      DOMAIN: ${{ inputs.DOMAIN }}
      OGCM:   ${{ inputs.OGCM }}
      BLK:    ${{ inputs.BLK }}
    steps:
      - run: bash croco_ops/pipeline.sh
```

The leaf is a one-step workflow, so `bash croco_ops/pipeline.sh` with the same env
vars is byte-identical behaviour at a prompt. **That property is the point of the
redesign.**

### D2 — systemd timer on the server triggers via `gh workflow run`

No `schedule:` in GitHub at all. The server decides what is doable; Actions is the
execution engine and the record.

```
systemd timer (Persistent=true)
  └─ dispatch/dispatch.sh
       ├─ compute RUN_DATE(s) in play
       ├─ for each candidate: work to do? resource free?
       └─ gh workflow run <wf>.yml -f RUN_DATE=... -f DOMAIN=... ...
```

Rationale:
- Every GitHub run then represents **real work** — the Actions list stays readable and
  failure emails stay meaningful. (A scheduled workflow that no-ops 23 times a day
  trains you to ignore the tab, and then the one real failure is missed.)
- GitHub's `schedule:` event is documented as delayable under load and **droppable**.
  Unacceptable for an operational system.
- `Persistent=true` gives catch-up after a reboot; GitHub cron has no equivalent.
- Gate logic lives in bash, in the repo, testable at a prompt.

**Costs, both must be handled:** `gh` CLI must be installed and authenticated on the
server (not currently present — needs a PAT with `repo` + `workflow` scope); and a dead
timer is now *silent*, so a dead-man's switch is required (`oceanmotion-models` uses
healthchecks.io — see `orchestrate/run_cycle.sh`).

### D3 — Resource-scoped `flock`, authoritative in the script

Not one global lock — **one lock per contended resource**:

- `model.lock` — model compute (MPI procs). CROCO, WW3, OpenDrift all contend.
- one lock per download source — two concurrent `download_GFS` runs would clobber each
  other's `.grb` files.

GFS downloading *while* CROCO runs is fine (different resources). Today these are
serialised for no reason.

```bash
exec 9>"${LOCK_DIR}/model.lock"
flock -n 9 || { echo "model.lock held — skipping"; exit 0; }
```

**The lock in the script is authoritative; the dispatcher's check is only an
optimisation.** The dispatcher cannot be authoritative — there is a multi-second window
between its check and the runner starting, and it cannot see a script being run by hand
at a prompt. The flock sees everything and needs no network. Worst case: an occasional
extra green "skipped" run, which is far cheaper than trying to make dispatch precise.

**Consequence:** `SAWS_OK` disappears as a concept. Today it is a workflow output
threaded through three files; now it is `[ -d downloads/SAWS/for_croco ]` at the gate.
The filesystem is the message bus.

### D4 — Gate on real product files; "not yet" ≠ "broken"

Gate on real files, not sentinels/markers — zero extra state, self-describing, and
forcing a re-run is `rm`.

- **Combo-level gate** = the archived per-cycle file is present (cheap early-exit).
- **Stage-level gates** = local products.

Both, and they don't conflict: if the archive mount misbehaves, retry costs seconds
because tides/bry-ini/croco_avg all skip and only the archive step re-runs.

Archive is per-cycle `YYYYMMDD_HH/`, which is **write-once** — unlike `latest/`, which is
rewritten every cycle and so proves nothing about which cycle it reflects.

**Two hard rules:**

1. **`exit 0` for "inputs not ready"; non-zero only for genuine breakage.** Waiting for
   HYCOM is not a failure. HYCOM present but CROCO blowing up is. Getting this wrong
   produces ~20 junk emails a day, notifications get muted, and the one real failure a
   month goes unseen.

2. **Size-equality check on the archive gate.** `postprocess_croco.yml` uses
   `rsync -rI --inplace` deliberately — *"the archive sits on a network mount that
   doesn't reliably allow overwriting/unlinking a file"*. `--inplace` writes bytes
   straight into the destination rather than temp-file-then-rename, so an interrupted
   first write leaves a **truncated file at the canonical name** that passes `[ -f ]`
   forever. One line closes it:

   ```bash
   [ -f "$dst" ] && [ "$(stat -c%s "$src")" = "$(stat -c%s "$dst")" ]
   ```

Where atomicity *is* available, use it: `oceanmotion`'s `run_croco.sh` already runs in
`scratch/`, checks `tail -2 croco.out | grep DONE`, and only then `mv`s into `output/`.
That `mv` is the success commit.

### D5 — `HDAYS=0`, archive raw only, no `ncks`

`HDAYS=0`, `FDAYS=5` (2.45 SAWS). The per-cycle archive is the raw output as
`croco_avg_frcst.nc` — **no `ncks` subset step**, since with `HDAYS=0` there is no
hindcast portion to chop off.

Sizing (sa_west_02: 130×448×30, hourly avg):

| | records | `croco_avg.nc` |
|---|---|---|
| today, per cycle (H5+F5) | 241 | ~8.4 GB |
| new, per cycle (H0+F5) | 121 | ~4.2 GB |
| new, `latest` (5 back + 5 fwd) | 241 | ~8.4 GB |

**The real prize is halved integration time** — 5 days instead of 10, across 8 combos —
not the disk saving. And `latest` lands at exactly today's per-cycle size, so
postprocessing it is size-neutral against what tier1/2/3 already handle.

### D6 — Postprocess runs on the concatenated `latest`, not per cycle

Per-cycle archive is raw only. A separate stage concatenates raw → `latest/raw`, then
regrids/plots `latest/raw` → `latest/postprocess`.

Rationale: tiered products are *derived* and regenerable, so the long-term archive
should hold raw; the front-end gets a continuous 10-day product rather than a 5-day
snapshot (the entire reason for concatenating); size-neutral; and fewer per-cycle stages
means faster retries.

**Accepted cost:** plots/animations are rebuilt over the full window every cycle rather
than being a kept per-cycle artifact. Anomalies (sa_west only, via `CLIM_FILE`) move onto
`latest` too.

### D7 — `latest/` is a contract, not an output

**Downstream services depend on the existing format. The new workflow must produce
`latest` directories identical to the current ones.**

Path: `/mnt/ocims-somisana/public-facing/{sa-west|sa-southeast}/v1.0/forecasts/latest/{OGCM}-{BLK}/`
(domain `sa_west_02` → strip last 3 chars → `sa_west` → `sa-west`)

| file | source |
|---|---|
| `croco_avg.nc` | raw, from `output/` — 10 days (5 back + 5 fwd) |
| `croco_avg_t1.nc` | `regrid_tier1` |
| `croco_avg_t2.nc` | `regrid_tier2 --depths 0,-5,-10,-50,-100,-500,-1000` |
| `croco_avg_t3.nc` | `regrid_tier3 --spacing 0.02` |
| `croco_avg_temp_{surf,bot,100m}.mp4` | `crocplot --skip_time 6` |
| `croco_avg_anom.nc` + 3 anom mp4s | **sa-west only** (`CLIM_FILE` set) |

Not present: `croco_avg_frcst.nc` (explicitly excluded; goes only to `somisana_safe`).
*(List confirmed complete.)*

**Two constraints this imposes:**

1. **The concatenated file must be named `croco_avg.nc`.** Tier filenames are derived
   from the input basename (`crocotools_py/regridding.py:121,211,535` —
   `basename_no_extension + '_t1'`), so any other name breaks `croco_avg_t1/t2/t3.nc`.
2. **Time encoding must not be re-encoded.** `concat_latest.py` is safe here — its
   docstring states *"none of them re-encode time on output"*, and `--yorig 2000` is the
   CROCO-native path for `units="second"`.

### D8 — `latest` window: backward walk with gap-stop

5 days back + forward (`FDAYS`, so 2.45 days for SAWS). Gap-free **by construction**
rather than by detection:

```
window = newest completed file          # covers [T0, T0+F]
cursor = T0
loop backwards over candidate run dates T_i < cursor:
    if archived file for T_i exists:
        if T_i + F >= cursor:           # its coverage reaches the cursor
            prepend slice [T_i, cursor) ;  cursor = T_i
        else:
            break                       # gap → stop extending
    stop when cursor <= T0 - 5 days
trim to [T0-5d, T0+F]
```

Taking only `[T_i, cursor)` from each older file **is** "latest run wins" exactly: for
any timestep `t`, the newest run covering it is the largest `T_j ≤ t`. So freshest-data-
per-timestep and gap-freedom fall out of the same rule. The result is always contiguous,
always ends at `T0+F`, and is between `F` and `5d+F` long.

Robustness at 1 cycle/day: SAWS `F=2.45d` = 58 hourly records, so a run at `T0-24h`
reaches `T0+34h` — it bridges comfortably and survives one missed day
(`T0-48h + 58h = T0+10h ≥ T0`). GFS at `F=5d` needs five consecutive failures to truncate.

### D9 — Full stateless rebuild, reading local files

Rebuild `latest` from scratch each cycle by walking per-cycle files. **Not** incremental
merge into the existing `latest`.

- The backward walk over per-cycle files *is* the D8 algorithm; incremental would have to
  infer the same thing from the existing `latest`'s time axis — a second code path
  expressing one rule, which is how the two drift.
- Rebuild is stateless: `latest` is a pure function of what is on disk. No corruption
  propagation, and a backfilled cycle is picked up for free.
- I/O saving of incremental is not the win it appears: ~25 GB vs ~13 GB read per combo,
  but both write the same 8.4 GB and then regrid it, which dominates. ~1.6×, not 10×.

**Read historical slices from local disk, not the archive mount** — they are the same
files, and pulling ~25 GB × 8 combos across a mount that `cleanup.yml` describes as one
that "can hang" is asking for trouble.

### D10 — Retention 5 → 8 days

The current 5-day `cleanup.yml` window is *exactly* the data the concat needs, with zero
margin. Sizing: 8 days × 8 combos × ~4.2 GB raw ≈ 270 GB plus `latest` and tiers.
Confirmed acceptable.

---

### D11 — Combos are a table; `my_env.sh` holds one run's defaults; one process per combo

`my_env.sh` stays what `oceanmotion` makes it: **defaults for a single run**. There are
no per-combo `.env` files — 14 files to express a 3-column, 8-row table is
over-engineering, and it isn't even better for testing (see below).

**The permutation list is one table**, read both by `dispatch.sh` (to fire 8 workflows)
and by a local `run_all_combos.sh` (to run them in series at a prompt) — the same table,
so the two cannot disagree about what is operational:

```
# combos_croco.txt  — the operational matrix; one row = one run
# DOMAIN          OGCM      BLK
sa_west_02        MERCATOR  GFS
sa_west_02        MERCATOR  SAWS
sa_west_02        HYCOM     GFS
sa_west_02        HYCOM     SAWS
sa_southeast_01   MERCATOR  GFS
sa_southeast_01   MERCATOR  SAWS
sa_southeast_01   HYCOM     GFS
sa_southeast_01   HYCOM     SAWS
```

**`FDAYS` and `CLIM_FILE` are derived inside `my_env.sh`** via `case` on `BLK` / `DOMAIN`.
They are genuine functions of those (`FDAYS=2.45` is a property of SAWS; `CLIM_FILE` is a
property of sa_west), not of the combination — and `my_env.sh` already derives
`RUN_NAME`, `CROCO_MPI_NUM_PROCS`, `RUN_DATE_FMT` and every path.

Testing one combo needs no file at all:

```bash
DOMAIN=sa_west_02 OGCM=MERCATOR BLK=SAWS bash croco_ops/run_croco.sh
```

#### ⚠ ONE FRESH PROCESS PER COMBO — a hard invariant

The `${VAR:-default}` idiom is **only safe in a clean environment**. A driver that loops
and exports silently contaminates later combos:

```bash
for BLK in GFS SAWS; do
  export BLK
  source my_env.sh      # FDAYS="${FDAYS:-5}" … then SAWS wants 2.45
  bash croco_ops/run_croco.sh
done
```

Iteration 1 (GFS) sets `FDAYS=5`. Iteration 2 is SAWS, but `FDAYS` is *already set*, so
`${FDAYS:-2.45}` never fires and **SAWS runs with `FDAYS=5`**. Per
`run_all_domains.yml`'s own comment, CROCO then runs out of SAWS forcing — after burning
90 processors to get there. The same leak applies to `CLIM_FILE`, `RUN_NAME` and every
derived path.

**Always use a prefix assignment**, which scopes the variables to that one command and
leaves the parent shell untouched:

```bash
DOMAIN="$d" OGCM="$o" BLK="$b" bash croco_ops/pipeline.sh
```

In production this is free — each combo is its own Actions job (D1), hence its own
process. The risk lives entirely in the local "run them all" convenience script.

**Rejected:** one script per permutation (8 copies of the same logic; a fix lands 8 times
and they drift). **Rejected:** nested cartesian loops to generate the list (correct today,
but needs a skip-list the moment one domain wants only a subset of forcings).

#### Robustness guards

- **Validate every table row before acting.** A short row leaves `BLK` empty,
  `${BLK:-GFS}` fires, and the wrong combo runs silently. Assert 3 non-empty fields and
  assert each value is in the known set, so a typo fails at dispatch rather than three
  hours into a run.
- **`set -euo pipefail` in every script.** Note `set -u` is *why* `oceanmotion`'s
  `my_env.sh` carries the `:-` guard on `RUN_DATE` — keep that pattern deliberate.
- **Print the resolved environment banner at the top of every run** (as `run_all.sh`
  already does), so any leak or typo is visible in the log after the fact.

### D12 — Read-only configs, per-cycle data, compile every cycle

**Config and data are separate.** `CONFIG_DIR` is read-only in the `somisana-croco`
clone; everything a cycle produces lives under `DATA_DIR`:

```
CONFIG_DIR = ${CROCO_REPO}/configs/${DOMAIN}/${MODEL}      # read-only, the clone
DATA_DIR/${RUN_DATE}/
    downloads/{GFS,SAWS,MERCATOR,HYCOM}/                   # cycle-level, shared by both
    ${DOMAIN}/croco_ops/                                    #   domains (one bbox covers both)
        ${COMP}/croco                                       # binary
        ${OGCM}/     croco_{bry,ini}_*.nc                   # per domain × ocean
        ${TIDE_FRC}/ croco_frc_*.nc                         # per domain
        ${RUN_NAME}/{scratch,output}                        # per combo
```

**Downloads sit at cycle level, not under domain** — a deliberate deviation from
`oceanmotion` (single-domain, so it nests them under the domain). The download bbox
`11,36,-39,-25` already covers both domains; nesting would duplicate GBs for nothing.

**The `{BRANCH_REF}` path level is dropped.** Branch isolation becomes
`DATA_DIR=/home/somisana/ops-test …` (`DATA_DIR` is overridable, as in `oceanmotion`'s
`.env`) — more flexible, and it removes a level from every path.

**CROCO is compiled every cycle, per domain.** `jobcomp_frcst.sh` compiles in place in
the clone (all artifacts gitignored — the intended workflow), then the binary is copied
to `${DATA_DIR}/${RUN_DATE}/${DOMAIN}/croco_ops/${COMP}/croco`. **That per-cycle copy is
the gate** — plain file presence, consistent with D4 — and it gives provenance: the exact
binary that produced any cycle is preserved beside its output.

Rationale: it eliminates staleness reasoning rather than trying to enumerate the
dependency set (a `make`-style staleness check would have to track `cppdefs.h`,
`param_.h`, `jobcomp_frcst.sh`, the CROCO source tree, the compiler and the MPI library —
and a missed dependency means silently forecasting with a stale binary). Two compiles a
day, a few minutes each.

**Accepted cost:** a bad `cppdefs.h` takes out all 4 combos of that domain for the cycle,
where a cached binary would keep running. Fail-fast is the right trade here — the
alternative fails silently for weeks. Compile is therefore its own early stage, so the
breakage is obvious and isolated rather than surfacing as 4 confusing run failures.

**Compile needs a per-domain `flock`** — `prep_domain.yml` warns that parallel compiles in
the same directory crash, and 4 combos now share each domain's binary.

### D13 — Restart chain: fall back to `${OGCM}_GFS` before cold-starting

**The indexing formula is correct for any `HDAYS`** — retiring the caveat in
`oceanmotion`'s `my_env.sh`. Previous run at `D_p` starts integrating at `D_p − H`, so its
record `k` sits at `D_p − H + k·6h`; the new run at `D_n` needs the record at `D_n − H`;
solving gives `k = (D_n − D_p)/6h`, which is exactly what both `run_croco.yml` and
`run_croco.sh` compute. The `H` cancels. (`croco_fcst.in`: `restart: NUMRST 0` —
`NRPFRST=0` accumulates all records in one file; `initial: NRREC = RST_STEP`.)

**The problem `HDAYS=0` creates.** `MAX_RST_STEPS = int(FDAYS × 24 / 6)`, correct because a
previous run's restart file only extends `FDAYS` past its own `T0`. But the lookback then
differs sharply per combo:

| | `FDAYS` | steps | lookback | consecutive daily misses survived |
|---|---|---|---|---|
| GFS | 5 | 20 | 120 h | 4 |
| SAWS | 2.45 | 9 | 54 h | 2 |

So a SAWS chain cold-starts after 3 consecutive misses — and SAWS is exactly the source
that goes missing. Under `HDAYS=0` a cold start has **no spin-up at all**: today's
`HDAYS=5` gives 5 days of integration before `T0`, which is the geostrophic adjustment
period; with `HDAYS=0` the adjustment shock lands *inside* the forecast window.

**The rule.** Restart search order is **own chain → `${OGCM}_GFS` → cold start**. The OGCM
is held fixed deliberately: the inherited interior state was then driven by the same
boundary conditions the new forecast is about to use. A restart file is the full interior
ocean state, so a GFS-forced state is a perfectly valid initial condition for a
SAWS-forced forecast — and vastly closer to reality than an interpolated OGCM field with
no adjustment.

Two details:

- **The fallback search uses the fallback chain's `MAX_RST_STEPS`, not the combo's** — a
  SAWS run searching `${OGCM}_GFS` history looks back 120 h, not 54 h, because those
  restart files extend 5 days. This effectively eliminates SAWS cold starts.
- **Search nearest-first, tie-break to own chain**: step back in 6 h increments and check
  own-then-fallback at *each* step. Exhausting the own chain first would prefer a 48 h-old
  own state over a 24 h-old `${OGCM}_GFS` state, and freshness dominates.

Make the fallback source configurable (`RST_FALLBACK_BLK="${RST_FALLBACK_BLK:-GFS}"`) so
replacing GFS as the reliable atmospheric source is a one-line change.

**Log the fallback loudly.** `RUN_NAME` stops being a self-contained lineage, so "what
state did this forecast come from?" must be answerable from the log, not inferred.

No ordering constraint follows from this: the search only ever looks at *previous* cycles
(the same cycle's `${OGCM}_GFS` run starts at `T0` and its first restart record is
`T0+6h`, so it cannot serve `T0` anyway).

**Rejected:** adaptive `HDAYS` for spin-up on cold start (Option C) — a second code path
that makes one cycle 60% longer exactly when already behind. True cold starts (a new
domain, or 5 straight failures) are rare enough to handle by hand.

### D14 — Downloads: same `HDAYS`/`FDAYS` as the model, `saeonapps` hop retained

**No separate download window.** The download CLIs already add their own buffer, so
`HDAYS=0` still yields a record strictly before `T0`:

| source | buffer | code |
|---|---|---|
| MERCATOR / CMEMS | `hdays + 1` | `somisana-download/download_tools/cmems.py:88` |
| GFS | `hdays + 0.25` (6 h) | `download_tools/gfs.py:141` |
| HYCOM | `hdays + 1`, `fdays + 1` | `download_tools/hycom.py:187` |

Download volume roughly halves as a side effect of `HDAYS=0` — on the slowest, least
reliable stage.

**⚠ The OGCM download window must be `max(FDAYS)` over the combos table, not the derived
per-`BLK` value.** MERCATOR feeds both `MERCATOR_GFS` (5 days) and `MERCATOR_SAWS` (2.45),
so the download must cover the longest run using it. This works today only because the
base default (5) coincides with the max — add a `BLK` with `FDAYS=7` and the OGCM
download silently stays at 5, and that run exhausts its boundary data mid-forecast.
Derive it from the table so it maintains itself.

**SAWS is not a download.** `reformat_saws_atm` reads `/mnt/saws-data/ocims` and uses
`GFS/for_croco` as `--backupDir` for variables SAWS does not provide. So SAWS genuinely
depends on GFS being downloaded **and reformatted** first — that ordering must survive
into the gates. MERCATOR / HYCOM / GFS are mutually independent and can run concurrently
on the 4 runners; only SAWS waits on GFS.

**The `saeonapps` hop stays.** `copernicusmarine` still cannot reach Copernicus from the
MIMS network, so MERCATOR downloads on the `saeonapps` runner and arrives via the shared
Samba mount. This fits the design unchanged: the dispatcher on `mims3` fires the workflow
and `runs-on: saeonapps` routes the job there — `gh workflow run` does not care where a
job executes — and the gate is evaluated on the shared mount, which `mims3` can see. Two
stages, two gates, as today.

### D15 — `RUN_DATE` is today's 00Z; current cycle only, no automatic backfill

`RUN_DATE = $(date -u +%Y%m%d)_00` — **not** `my_env.sh`'s nearest-12h auto-compute, for
`oceanmotion`'s stated reason: a `Persistent=true` timer catching up after 12:00 UTC must
still run the daily 00Z cycle rather than chase a 12Z dataset that is not published yet.

**Publication schedules never need encoding.** The dispatcher fires every 15–30 min from
00:00 UTC; the 00Z GFS does not publish until ~04:00, so early firings simply find gates
saying "not yet" and exit 0 — no cost, no GitHub runs. The system starts the moment data
appears, which is strictly better than today's fixed 03:00 cron that fires once and hopes.

**The dispatcher only ever works on the current cycle**, retrying continuously for ~24 h
until `RUN_DATE` rolls over. Missed cycles are not automatically backfilled;
`RUN_DATE=20260801_00 bash …` does it by hand.

Rationale:
- Backfill would repair problems already mitigated by design — a truncated `latest`
  window (D8's gap-stop degrades gracefully) and a longer restart reach (D13's
  `${OGCM}_GFS` fallback bridges it).
- Backfill is frequently impossible anyway: if HYCOM was unreachable all day, tomorrow's
  attempt at yesterday's cycle needs *yesterday's* HYCOM data, which may have aged out
  upstream. The failure that causes the gap often also prevents its repair.
- ~96 dispatch attempts a day means any transient failure self-heals unnoticed. A cycle
  that fails for a whole day is not transient — it is a mount down or a disk full, and it
  wants a human, not a retry.

**Accepted cost:** a permanent hole in the per-cycle archive for that date, and up to
5 days of slightly-short `latest` windows. Both visible, neither corrupting.

Option B (current + N days back, newest-first) remains available later — it is a loop
around the same gate logic in `dispatch.sh`, not a redesign.

### D16 — Alerting: GitHub's native emails plus a 12:00 completeness check

No new alerting infrastructure. Two decisions had opened a gap that this closes:

- **D4 made silence a valid state.** "Inputs not ready" exits 0 — correct, and what keeps
  notifications meaningful — but a gate that will *never* be satisfied looks identical to
  one about to be. If HYCOM stops publishing or the SAWS mount silently unmounts, the
  system reports success all day and just does less work.
- **D2 removed GitHub's scheduling guarantee.** With `schedule:` gone, a dead timer means
  no workflow runs, so GitHub has nothing to fail and nothing to email about.

| failure mode | detected by |
|---|---|
| a stage runs and fails | GitHub's native failure email |
| a gate is never satisfied → silent stall | **the 12:00 completeness check** |
| dispatcher/box dead → nothing runs | the completeness check (it also stops running → no daily green) |

**`check_cycle.sh`, dispatched once daily at 12:00 UTC.** It asserts the affirmative: for
today's `RUN_DATE`, **all 8 combos** are archived, each combo's model `latest` is fresh,
and **each** forcing source's `latest` (D20) is fresh. Anything missing → non-zero → the
run goes red → GitHub emails.

Checking the forcing sources *individually* is what closes the loop on D20's per-source
skipping: a source that quietly skips every cycle because its download never lands looks
healthy at the stage level, and only this check exposes it. This is the *same gate functions,
inverted*, so there is no second body of logic to maintain, and it rides the existing
notification path.

12:00 is safe for SAWS: a SAWS file initialised at `RUN_DATE − 12 h` carries 72 h, so it
covers to `RUN_DATE + 60 h`, and its 12 h transfer latency puts it on the mount by
`RUN_DATE` itself — i.e. present at cycle start, not at noon. (`FDAYS=2.45` = 58.8 h fits
just inside the 60 h, which is the "just over 1 hour less" margin `run_all_domains.yml`
describes.)

**Fix carried over from today's system.** `download_surface.yml` marks the SAWS reformat
`continue-on-error: true` and converts the outcome into `SAWS_OK`, which then skips the
SAWS legs — so **everything reports success and four forecasts silently do not happen**.
In the new design:

- Absent SAWS input → **exit 0** (at 00:15 UTC absence is normal; failing here would go
  red every morning and rebuild alert fatigue from the other direction). The 12:00 check
  is what distinguishes "not yet" from "never", because the distinction is *time*.
- The reformat **crashing on input that is present** → **non-zero, immediately**. Today's
  `continue-on-error: true` conflates a Python traceback on corrupt data with normal
  absence; the new script tests for the input explicitly and only that case exits 0.

Also keep `oceanmotion`'s fixed `latest_run.status` one-liner for humans — `cat` it on the
box to see what the cycle is doing. Observability only; it must never feed a decision.

### D17 — Postprocess: built locally, own lock, one at a time

D6 creates **8 latest-build pipelines per cycle** (one per `domain × OGCM-BLK`), each
doing concat → `tier1` → `tier2` → `tier3` → 3 × `crocplot` → (sa-west) anomalies + 3 more
plots → rsync. Their resource profile is the opposite of CROCO's:

| | CROCO | postprocess |
|---|---|---|
| cores | 90 (sa_west) / 24 (sa_southeast), MPI | 1 |
| memory | modest | up to 35 GB (today's `--memory=35g` on tier2) |
| bound by | CPU | memory + I/O |

**`latest` is built locally** at `${DATA_DIR}/latest/${DOMAIN}/${OGCM}-${BLK}/` and rsynced
to the mount as a separate gated step — a consequence of D9 reading per-cycle files from
local disk. This also gives a gate with no new state: `latest` is current iff
`latest/croco_avg.nc` is **newer than this cycle's raw output** (`-nt` on local files).
Doing this on the mount would be unreliable — `rsync -rI` omits `-t`, so destination
mtimes are rewrite times, not source times.

**⚠ The gate compares against the newest per-cycle file that EXISTS**, not against "this
cycle's" file. If this cycle's run failed, comparing against a non-existent file reads as
"not current" and triggers a rebuild that reproduces the identical window from the
previous cycle's data. Newest-existing makes the no-new-data case a clean skip. (A manual
backfill of an older cycle still triggers a rebuild, correctly, since its mtime is newer.)

**Postprocess takes its own `postprocess.lock`, one at a time.** It may overlap CROCO
(CPU-bound vs memory/I/O-bound — they complement rather than compete) but never itself.
This makes the memory ceiling a property of the design rather than of how many runners
happen to be idle. Rejected: sharing `model.lock` (idles cores during postprocess and
memory during CROCO); N concurrent slots (sizes concurrency against peak memory, and
works right up until tier2 needs more).

### D18 — One archived product per cycle; WW3 reads the surface level from the 3D file

**`croco_avg_surf.nc` is not archived.** In somisana `myenv_in.sh` sets **both** `NH_AVG=1`
and `NH_AVGSURF=1`, so the 3D file is already hourly and the surface file is pure
duplication. (`oceanmotion` needs it only because its 3D output is not hourly.) CROCO
still *writes* it — no config change in `somisana-croco`, and it stays on local disk for
the same-cycle WW3 path — it is simply not archived.

**So the per-cycle archive is exactly one file**, `croco_avg_frcst.nc` (the raw output
renamed; no `ncks`, per D5), and it is self-contained for both downstream models:

- **OpenDrift** already works with it — `opendrift_tools/preprocess.py:53-59` reads
  *native* CROCO files via `reader_ROMS_native`, with `set_croco_time` patching the
  reference time because "native croco files do not contain reference time". This
  independently reinforces D7: the concatenated `latest/croco_avg.nc` **must** keep
  CROCO's native time encoding or OpenDrift's reader breaks too.
- **WW3 needs a small upstream change** (see below).

**Not archived, deliberately:** `croco_rst.nc` (with `NRPFRST=0` it accumulates ~20 full 3D
states, ~700 MB/combo/cycle, and its only consumer is the restart chain reading local disk
inside the 8-day window). `croco_his.nc` is never written at all (`history: LDEFHIS = F`),
and station output is disabled — time-series are extracted in postprocessing instead.

#### ⚠ Cross-repo prerequisite for the WW3 phase (in `somisana-croco`, not this repo)

`oceanmotion`'s `make_croco_forcing.sh` hard-fails without `croco_avg_surf.nc` and feeds it
to `croco_srf_2_ww3`. That function must learn to take the surface level from a 3D file.
It is a small, contained change — `croco_srf_2_ww3` already delegates to accessors that
both accept a level:

```
crocotools_py/postprocess.py:684  def get_var(fname, var_str, ..., level=slice(None), ...)
crocotools_py/postprocess.py:861  def get_uv(fname, ..., level=slice(None), ...)
```

It currently passes nothing, so `level` defaults to `slice(None)` — which works on a 2D
surface file only because there is one level. Add a `level` argument and thread it
through; surface is sigma index `-1` (`crocplot --level 0` = *bottom* confirms 0 is the
bottom).

### D19 — Credentials live in `.env` on the hosts, not in GitHub secrets

`.env`, `chmod 600`, gitignored, sourced by the scripts (`oceanmotion`'s pattern).
**GitHub Actions carries no secrets at all** — the runner *is* the box, so it reads the
same file.

The deciding reason: **if credentials come from GitHub secrets, a hand-run script has
none.** The entire premise of this rewrite is that
`RUN_DATE=… bash download/download_MERCATOR.sh` behaves identically at a prompt and on
the runner; GitHub secrets break that for precisely the stage that is flakiest and most in
need of manual testing. Secondary: credentials never transit GitHub and cannot leak into
workflow logs.

Neither host needs both secrets:

| host | needs |
|---|---|
| `mims3` | `gh` PAT (for `gh auth`), plus `DATA_DIR` and other host overrides |
| `saeonapps` | `COPERNICUS_USERNAME` / `PASSWORD` |

`mims3` never touches Copernicus — it only copies from the shared Samba mount — and it
needs a credential file anyway for `gh auth`, so this adds no new *kind* of thing to
manage.

**Accepted cost:** two `.env` files on two hosts rather than one GitHub secrets page, so
rotation is a two-place operation with no UI. That is what `deploy/runbook.md` is for.

### D20 — A `latest` for the downloaded forcing too (public-facing, SAWS excluded)

The spatially-subset forcing downloads get their own rolling window: the most recent
download concatenated with previous cycles back **5 days**, forward to whatever the newest
download covers (`T0 + FDAYS` plus each source's built-in buffer) — the same 10-day span
as the model `latest`, with no extra parameter. Same backward-walk-with-gap-stop algorithm
as D8, reused rather than reimplemented. `oceanmotion`'s `build_latest_raw.sh` already
concatenates downloads this way, so the machinery ports over.

**Purpose:** public-facing, to drive a separate front-end display.

**⚠ SAWS is excluded.** `download_surface.yml` states *"we intentionally do not copy saws
data as the archive dir is public facing"*. A naive "concatenate all sources" would
publish data that is deliberately withheld. Only **GFS, MERCATOR and HYCOM** get a
forcing `latest`.

**It is its own stage, run once per cycle.** Downloads are cycle-level (D12) — shared
across domains and combos — but the postprocess pipeline runs **per combo, 8 times**.
Folding this in would rebuild identical files 8× per cycle. So `build_latest_downloads.sh`
is separately gated and separately dispatched, sharing `postprocess.lock`.

**Paths.** Built locally at `${DATA_DIR}/latest/downloads/{SOURCE}/`, then rsynced to
`/mnt/ocims-somisana/public-facing/sa-forcing/latest/{SOURCE}/`, mirroring the per-cycle
`sa-forcing/{run_date}/{SOURCE}/` layout.

#### ⚠ Per-source independence — one failed download must not block the others

**Gating is per source, never all-or-nothing.** Each of GFS / MERCATOR / HYCOM is gated,
built and reported separately, using the D17 rule: that source's `latest` is current iff
newer than **the newest per-cycle file of that source that exists**. Consequences:

- **This cycle's HYCOM download failed** → HYCOM's `latest` is already newer than the most
  recent HYCOM file on disk → **skip, exit 0**. It correctly remains the concatenation of
  everything available, one cycle staler. GFS and MERCATOR rebuild normally.
- **A source's concat crashes on data that IS present** → that source goes red — but only
  after the others have been attempted.

**`set -euo pipefail` will defeat this if applied naively:** a crash in the GFS concat
aborts the script before MERCATOR runs. The loop must attempt **every** source, collect
failures, and exit non-zero at the end only if something genuinely failed — the same shape
as `oceanmotion`'s `wait_jobs`. Skips are not failures (D4).

This is the same principle the whole design rests on, applied one level down: per the
original brief, *"a failed HYCOM download doesn't stop a Mercator forced workflow"*.

**⚠ Time encoding — the one real trap** (`oceanmotion`'s `concat_latest.py` documents it):

| source | files | time handling |
|---|---|---|
| MERCATOR | `MERCATOR_{RUN_DATE}.nc` | CF, auto-decodes |
| HYCOM | `HYCOM_{RUN_DATE}.nc` | CF, auto-decodes |
| GFS | `for_croco/*.nc` — 10 per-variable files | **non-CF** `"days since 1-Jan-2000"`; xarray cannot parse it → explicit `--time_units "days since ${YORIG}-01-01"` |

Raw `.grb` files are **not** concatenated — they stay in the per-cycle dirs. For MERCATOR,
the glob must stay case-sensitive (`${OGCM}_*`) so it picks up only the combined file and
not the lowercase per-variable intermediates (`so`, `thetao`, `uo_vo`, `zos`).

**Cheap.** On the `11,36,-39,-25` bbox: GFS `for_croco` ≈ 10 MB/cycle across its 10 files
(~20 MB concatenated); MERCATOR is the largest at roughly 400 MB over the window. Against
8.4 GB per model-`latest` combo, this is noise.

**No existing contract — but it becomes one.** There is no `sa-forcing/latest/` today, only
per-`run_date` directories, so nothing downstream constrains the design. Once the
front-end ships, this acquires exactly the D7 property: adding files stays safe, renaming
or removing them breaks consumers silently. Choose the layout and filenames deliberately
now, while that is still free.

**Add it to the 12:00 completeness bar (D16)** — it is a daily deliverable like any other.

### D21 — Docker only on `saeonapps`; native conda for everything on `mims3`

| host | how the CLIs run |
|---|---|
| `mims3` | **native conda** — `somisana_croco` for the CROCO CLI, a `download` env for the download CLI |
| `saeonapps` | **Docker** — `ghcr.io/saeon/somisana-download_main:latest`, for the MERCATOR download only |

Rationale: `mims3` is ours, so native execution keeps every script hand-runnable (D19's
argument) and drops the image pull plus the `--user $(id -u):$(id -g)` and root-owned-output
workarounds. `saeonapps` is a borrowed host where the Docker image avoids having to install
and maintain a conda environment we don't control.

**This is a change for GFS and HYCOM**, which run in Docker today — they move to native
conda on `mims3`. **No new setup is needed: the `somisana-download` clone and its conda env
already exist on `mims3`.** (The workflows never reference them because they went the
Docker route, so the exact path and env name still want confirming on the box — §7.9.)

`saeonapps` keeps what it has: `docker pull` before use, and the existing
"use the image to delete the files the image created" cleanup for root-owned output.

### D22 — Every repo is pulled once per cycle, by the dispatcher

`sync_repos.sh` brings `somisana-croco`, `somisana-download` (and later `somisana-ww3`,
`somisana-opendrift`) up to date so each cycle runs the latest configs and CLI code.

**The dispatcher is the only thing that pulls.** Not each workflow — for three reasons:

1. **Consistency across combos.** One pull per cycle means all 8 combos see identical
   configs. Per-workflow pulls let a push mid-cycle leave combos 1–4 on one config and 5–8
   on another, with nothing in the archive recording which.
2. **No concurrent-git races.** Several workflows pulling the same clone at once contend on
   git's index lock.
3. **It's already the single entry point** and runs before anything is dispatched.

**⚠ `somisana-ops` must NOT be pulled by `sync_repos.sh`.** Bash reads scripts
incrementally, so pulling the repo containing the currently-executing script can corrupt
execution mid-flight. **The systemd service pulls `somisana-ops` *before* invoking
`dispatch.sh`**, and `sync_repos.sh` handles only the other repos.

Details:
- Workflows run scripts from the **persistent clone** (`/home/somisana/code/somisana-ops`),
  not an `actions/checkout` workspace — otherwise the dispatcher and the workflow it fired
  could be running different code.
- Branch is `main` by default, overridable (D12 dropped the `BRANCH_REF` path level;
  branch testing is now `DATA_DIR=…` plus a checked-out branch).
- **A failed pull warns and continues.** The previously-pulled code is still valid, and a
  network blip must not stop a forecast. Compile artifacts are all gitignored (see §3), so
  the working trees stay clean and pulls should not conflict.
- **Record each repo's resolved SHA in the cycle log**, so if a mid-cycle push ever does
  cause divergence it is visible afterwards rather than invisible. Pushing mid-cycle is
  discouraged.

### D23 — Bring-up runs in parallel on real filesystems, isolated by three roots

The new system is built and tested **alongside** the live one, writing to parallel roots on
the *same* filesystems. Cutover is then deleting three `.env` overrides — no code change.

```bash
DATA_DIR=/home/somisana/ops-test           # full 8-day retention; latest is built here
PUBLIC_ROOT=/mnt/ocims-somisana/_test      # replaces …/public-facing
SAFE_ROOT=/mnt/somisana_safe/models/_test  # replaces …/models
```

**Why not `/tmp`:** ~340 GB is more than `/tmp` usually has (it is often `tmpfs`);
`systemd-tmpfiles` reaps it on a schedule we do not control, which would show up as a
mysterious gap in the `latest` window; and it exercises none of the network-mount behaviour
that several decisions exist for (D4's size-equality check exists *because*
`rsync --inplace` is non-atomic on the ocims mount; `cleanup.yml`'s timeouts exist because
it hangs). Testing on the real filesystems tests the real failure modes.

**`PUBLIC_ROOT` sits OUTSIDE `public-facing/`**, which is genuinely public — served via
THREDDS. Structural exclusion, not a naming convention: a dot-prefixed
`public-facing/.test` would be hidden only by shell convention, and THREDDS does not
inherently skip dot-directories — whether it is served depends on the catalog's
`datasetScan` filters. `_test` as a sibling is excluded by the catalog's own scope.

There is plenty of space there, so the test tree **mirrors the real public-facing layout
faithfully** — same `{ARCHIVE_NAME}/{VERSION}/forecasts/…` structure, same retention. That
makes it a true dress rehearsal, and makes validation a straight `diff -r` between two
parallel trees.

**`RUN_DATE` uses the `_12` cycle**, not `_00`. Belt and braces: even with roots
redirected, any script that ever turns out to have a hardcoded live path writes to a
distinct `run_date` directory instead of clobbering live. It also avoids competing with the
live cycle for the same download window at the same wall-clock time.

**Build the hindcast up naturally rather than backfilling.** Letting `latest` grow
1 day → 2 → … → 5 exercises the backward-walk and gap-stop at *every* window length,
including the truncated case, which is otherwise awkward to produce deliberately. It also
exercises the day-to-day behaviour a same-afternoon backfill cannot: the restart chain
picking up yesterday's file, the dispatcher's 24 h retry window, `latest` rolling a day off
the back. D15's manual backfill stays available to accelerate, but let several days accrue
naturally first.

**⚠ Contract validation is structural, not numerical.** `HDAYS=0` versus live's `HDAYS=5`
means different initial conditions, so values legitimately differ. What must match is
filenames, variables, dimensions, time encoding and attributes — what downstream actually
binds to. Most of this is a **read-only** diff against the live `latest/`; no write to the
real public tree is needed at any point.

**⚠ Redirecting output does not solve CPU contention.** `RUN_DATE` controls *which data*,
not *when it runs* — a test CROCO taking 90 procs while the live 03:00 cycle is mid-run
blows through the 120-processor ceiling (§7.4). Run tests when live is idle, or override the
MPI decomposition in the test `.env`.

---

## 3. Established facts

- **Host:** self-hosted runners are named `mims3-runner_*`, but the box's actual
  `hostname` is `croco.fearon.alma.10` (confirmed 2026-08-03, AlmaLinux 10). Same
  machine — likely renamed during an OS upgrade — but worth knowing the two names
  don't match if you're cross-referencing against anything that keys off `hostname`.
- **Runners: 5 croco + 4 already-running OpenDrift, not 4.** Confirmed via
  `systemctl list-units`: `mims3-runner_croco1`–`croco5` (against
  `SAEON/somisana-croco`) plus `mims3-runner_od1`–`od4` (against
  `SAEON/somisana-opendrift`). OpenDrift is not hypothetical future work — it has its
  own operational pipeline running today (public-facing OpenDrift output on
  `ocims-somisana` dates back to 2023). D1/D2's "one runner busy, 3 free" concurrency
  reasoning was sized against 4 croco runners — recheck against 5 when Phase 5 lands.
  124 physical cores total (`nproc`), so the 114-vs-120 headroom in §7.4 is unaffected.
- **Cycle frequency:** 1/day (unchanged). Confirmed live: `/home/somisana/ops/main/`
  has one `YYYYMMDD_00/` directory per day through today (2026-08-03), ~74 GB/cycle —
  i.e. **the live system is running on this box right now**, which is exactly what
  D23's parallel-roots isolation exists to protect.
- **`gh` CLI is already installed and authenticated** (confirmed 2026-08-03, contradicts
  the earlier assumption that it still needed setting up): `/bin/gh` v2.97.0, logged in
  as `GilesFearon` under the `somisana` user, all three scopes (`repo`, `workflow`,
  `read:org`) present, `~/.config/gh/hosts.yml` is `600`. `deploy/runbook.md` §1 is
  therefore already done on this host — treat it as reference material for
  re-authentication/rotation elsewhere, not a pending task.
- `concat_latest.py` (`oceanmotion-models/ops/postprocess/`, 249 lines) is a good base —
  the fiddly time-encoding handling is already correct — but has **no gap detection**
  (sorts by time, concatenates latest-wins, trims to window at `:101,144,155`). The D8
  backward-walk needs adding on the front.
- Grid dimensions: `sa_west_02` 130×448×30, `sa_southeast_01` 152×106,
  `sa_eez_01` 817×111.
- `myenv_in.sh` (sa_west I99): `DT=60`, `NH_AVG=1`, `NH_RST=6`.
- **MPI decomposition lives in `somisana-croco`, per domain**
  (`configs/{domain}/{model}/myenv_frcst.sh`): `sa_west_02` = 5×18 = **90 procs**,
  `sa_southeast_01` = 6×4 = **24 procs**. Together 114, against the stated 120-processor
  ceiling in `run_ops_server.yml` — which is why domains cannot run concurrently.
- **`somisana-croco` is built for in-place compilation.** Its `.gitignore` already covers
  `Compile`, `croco`, `param.h`, `C*_I*_*` (run dirs), `**/scratch`, `**/output`, and
  `*.nc*` (except `*grd.nc*`). `C06/` tracks only `cppdefs.h` and `param_.h`; the working
  tree is clean. So compiling inside the config clone does not dirty git.

---

## 4. Deferred to implementation

No blocking design questions remain. These are mechanical and get settled while writing
the code:

- **Download retry policy** — counts and backoff. `oceanmotion`'s `download_all.sh` has a
  `retry()` wrapper with `DL_RETRIES=3` / `DL_RETRY_DELAY=180`; today's workflows use
  `nick-fields/retry` with 3–10 attempts and 300 s waits. Note the dispatcher already
  retries every tick, so in-script retries only need to cover *transient* upstream
  hiccups, not outages.
- **Cleanup/retention specifics** — local `DATA_DIR` at 8 days (D10); the ocims
  public-facing archive at 6 days and the `saeon-somisana` shared mount at 5 (as today);
  `somisana_safe` is long-term. All the network-mount hardening in today's `cleanup.yml`
  (30-min step timeout, `timeout -k 10 90 rm -rf`, warn-don't-fail per directory) carries
  over unchanged — it exists for good reasons.
- **`gh` CLI + systemd install steps** — these belong in `deploy/runbook.md`.
- **WW3 / OpenDrift combos tables** — deferred to those phases. The structure absorbs them
  (a second table, a second dispatch rule, sharing `model.lock`); the one known
  prerequisite is the `croco_srf_2_ww3` change recorded in D18.

---

## 5. Repo skeleton

```
somisana-ops/
├── README.md
├── .gitignore                        # .env, __pycache__
├── my_env.sh                         # ALL defaults for ONE run; derives FDAYS, CLIM_FILE,
│                                     #   RUN_NAME, paths (D11)
├── .env.example                      # real .env is gitignored, chmod 600 (D19)
├── combos_croco.txt                  # the operational matrix, 8 rows (D11)
├── run_all_combos.sh                 # local convenience: loop the table,
│                                     #   ONE FRESH PROCESS PER ROW (D11)
├── lib/
│   ├── common.sh                     # set -euo pipefail, logging, resolved-env banner
│   ├── lock.sh                       # flock helpers: model / postprocess / per-source
│   └── gates.sh                      # is_done() / inputs_ready() predicates — shared by
│                                     #   dispatch, the pipelines AND check_cycle (D16)
├── dispatch/
│   ├── dispatch.sh                   # the only orchestration logic (D2, D15)
│   ├── sync_repos.sh                 # git pull the OTHER repos, once per cycle (D22)
│   └── check_cycle.sh                # 12:00 completeness assertion (D16)
├── download/
│   ├── download_GFS.sh
│   ├── download_SAWS.sh              # reformat, not download; needs GFS first (D14)
│   ├── download_MERCATOR.sh          # runs on saeonapps
│   ├── collect_MERCATOR.sh           # mims3-side copy from the shared mount
│   └── download_HYCOM.sh
├── croco_ops/
│   ├── pipeline.sh                   # gate → compile → tides → bry/ini → run → archive
│   ├── compile.sh                    # per-domain flock (D12)
│   ├── make_tides.sh
│   ├── make_bry_ini.sh
│   ├── run_croco.sh                  # restart search incl. ${OGCM}_GFS fallback (D13)
│   └── archive.sh                    # → YYYYMMDD_HH/croco_avg_frcst.nc, size-checked (D4)
├── postprocess/
│   ├── pipeline.sh                   # gate → build_latest → regrid → plots → anomalies
│   │                                 #   → publish
│   ├── build_latest.sh               # backward walk with gap-stop (D8, D9)
│   ├── build_latest_downloads.sh     # forcing latest — ONCE per cycle, not per combo (D20)
│   ├── concat_latest.py              # ported from oceanmotion + the gap-stop it lacks
│   ├── regrid.sh                     # tier1/2/3
│   ├── plots.sh                      # crocplot × 3
│   ├── anomalies.sh                  # sa-west only (CLIM_FILE set)
│   └── publish_latest.sh             # rsync local latest → ocims mount
├── cleanup/
│   └── cleanup.sh                    # likely grows: local / ocims archive / saeon mount
├── deploy/
│   ├── runbook.md                    # gh auth, .env, systemd install, rotation
│   └── systemd/
│       ├── somisana_dispatch.service
│       ├── somisana_dispatch.timer   # Persistent=true (D2)
│       └── install_units.sh
├── plans/
│   └── operational_workflow_plan.md  # this file
└── .github/workflows/
    ├── download_gfs.yml
    ├── download_saws.yml
    ├── download_mercator.yml         # 2 jobs: saeonapps download → mims3 collect
    ├── download_hycom.yml
    ├── run_croco.yml                 # LEAF: one combo (D1)
    ├── run_croco_all.yml             # PARENT: 8 chained calls, needs: + if: always()
    ├── postprocess_croco.yml         # LEAF: one combo's latest build
    ├── postprocess_croco_all.yml     # PARENT: 8 chained calls
    ├── latest_downloads.yml          # forcing latest — once per cycle (D20)
    ├── check_cycle.yml               # fired at 12:00 by the dispatcher
    └── cleanup.yml
```

### Notes on the shape

**The dispatcher fires *parents*, not 8 leaves.** Firing 8 leaves at once would put 4 on
runners and leave 4 queued, with 3 of the 4 immediately exiting on `flock -n` — i.e. a
burst of skipped runs every tick. One parent per model instead: 8 jobs chained with
`needs:` + `if: always()`, so GitHub's own DAG serialises them, each self-gating and
skipping in seconds when already done. Per-combo visibility and re-run buttons are
retained (they are jobs), and only **one runner** is occupied at a time — leaving the
other 3 free for downloads, which is exactly what the resource-scoped locks (D3) were for.

**CROCO and postprocess parents run concurrently**, on different locks (D17): 2 runners
busy, 2 free. That fits 4 runners without tuning.

**`lib/gates.sh` is the keystone.** The same predicates answer "should I run this?"
(dispatch, pipelines) and "should this already be finished?" (`check_cycle`). D16's
promise that the completeness check is *the same logic inverted* only holds if there is
literally one implementation.

**`run_all_combos.sh` is where the D11 invariant is easiest to break.** It must invoke a
fresh process per row (`DOMAIN=… OGCM=… BLK=… bash croco_ops/pipeline.sh`), never
`source` in a loop.

---

## 6. Build order

Each phase is fully hand-runnable before the next begins — no automation exists until
Phase 4, which is the point of the design.

1. **Foundations** — `my_env.sh`, `lib/`, `combos_croco.txt`, `.env.example`.
   *Test:* source it, print the resolved banner for each of the 8 rows, confirm `FDAYS`
   and `CLIM_FILE` derive correctly and nothing leaks between rows.
2. **Downloads** — the 5 download scripts.
   *Test:* run each by hand for a real `RUN_DATE`; confirm gates skip on re-run; confirm
   SAWS exits 0 when its input is absent and non-zero when it is present but broken.
3. **CROCO pipeline** — `croco_ops/*`.
   *Test:* one combo end-to-end by hand; then all 8 via `run_all_combos.sh`. Verify the
   restart search picks up `${OGCM}_GFS` when the own chain is broken.
4. **Postprocess + `latest`** — `postprocess/*`. **This is the validation gate for the
   whole project:** the model `latest/` tree it produces must match what the current system
   produces, file for file (D7). Diff against the live archive before going further.
   The forcing `latest` (D20) also lands in this phase — it has no existing counterpart to
   diff against, so validate it by inspection, and settle its layout and filenames here
   while doing so, before the front-end turns them into a contract.
5. **Automation** — `dispatch.sh`, the workflows, systemd units, `gh` auth.
   *Test:* run alongside the live system on D23's test roots, accumulating cycles daily
   until `latest` reaches its full 5-day hindcast. Phases 4 and 5 overlap here by design —
   the accumulation period *is* the parallel-run period.
6. **Hardening** — `check_cycle.sh`, `cleanup.sh`, `runbook.md`.
7. **Cutover** — delete the three D23 `.env` overrides, then retire the `somisana-croco`
   workflows.

Phases 1–4 need no GitHub, no `gh`, no systemd, and no changes to the running operational
system. **Everything runs on `mims3`** from Phase 2 onward (real data, real mounts, real
conda envs, real CROCO), isolated by the D23 roots.

---

## 7. Concrete values

Every literal `my_env.sh` and the stage scripts need, with the file each came from so it
can be re-verified. Sources are in `somisana-croco/.github/workflows/` unless stated.
**Verify against the live server before first run** — these are read out of the current
workflows, which is authoritative for intent but not a guarantee the box still matches.

### 7.1 Hosts

| | |
|---|---|
| compute / runner | `mims3`, **5 croco runners + 4 opendrift runners** (confirmed 2026-08-03; see §3) |
| MERCATOR download | `saeonapps` runner (D14 — the hop stays) |
| runner group / perms | `chown -R :runners`, `chmod -R 775` (used throughout today) |

### 7.2 Paths and tooling on `mims3`

| variable | value | source |
|---|---|---|
| `CROCO_REPO` | `/home/somisana/code/somisana-croco` | `run_ops_server.yml` |
| conda hook | `/home/somisana/miniforge3/etc/profile.d/conda.sh` | `make_bry_ini.yml` |
| `CROCO_ENV` | `somisana_croco` | `make_bry_ini.yml` |
| `DOWNLOAD_REPO` | `/home/somisana/code/somisana-download` | **confirmed** 2026-08-03 (directory present, has `cli.py`); path not in any workflow, so this repo is the source of truth now |
| `DOWNLOAD_ENV` | `download` | **confirmed** 2026-08-03 (`conda env list`, alongside `somisana_croco`) |
| `OPS_REPO` | `/home/somisana/code/somisana-ops` | **new** — persistent clone; workflows run from here, not a checkout workspace (D22) |
| `CROCO_SOURCE` | `/home/$USER/code/croco-v1.3.1/OCEAN/` | `configs/*/croco_v1.3.1/myenv_frcst.sh` |
| `TPXO_DATA_DIR` | `/home/somisana/data/TPXO10` | `make_tides.yml` (`/home/somisana/data/${TIDE_FRC}`) |
| SAWS source dir | `/mnt/saws-data/ocims` | `download_surface.yml` |
| `DATA_DIR` | replaces `/home/somisana/ops/{BRANCH_REF}/` — branch level dropped (D12). Test: `/home/somisana/ops-test` | D12, D23 |
| `PUBLIC_ROOT` | `/mnt/ocims-somisana/public-facing`. Test: `/mnt/ocims-somisana/_test` | D23 |
| `SAFE_ROOT` | `/mnt/somisana_safe/models`. Test: `/mnt/somisana_safe/models/_test` | D23 |

The three roots above are the **only** difference between the test and live systems (D23) —
cutover deletes the overrides.

### 7.3 Model identifiers — identical across all 8 combos → `my_env.sh`

| variable | value |
|---|---|
| `MODEL` | `croco_v1.3.1` |
| `VERSION` | `v1.0` (archive path component) |
| `COMP` | `C06` |
| `INP` | `I99` |
| `TIDE_FRC` | `TPXO10` |
| `YORIG` | `2000` |
| `HDAYS` | `0` (D5) |
| `FDAYS` | `5`, or `2.45` when `BLK=SAWS` (derived, D11) |

Source: `run_all_domains.yml`. `RUN_NAME = ${COMP}_${INP}_${OGCM}_${BLK}_${TIDE_FRC}`
→ e.g. `C06_I99_MERCATOR_GFS_TPXO10`.

### 7.4 Per-domain values — derived from `DOMAIN` in `my_env.sh` (D11)

| | `sa_west_02` | `sa_southeast_01` |
|---|---|---|
| `ARCHIVE_NAME` | `sa-west` | `sa-southeast` |
| MPI (`MPI_NUM_X` × `Y`) | 5 × 18 = **90** | 6 × 4 = **24** |
| grid (rho) | 130 × 448 × 30 | 152 × 106 |
| `CLIM_FILE` | `/mnt/ocims-somisana/public-facing/sa-west/v1.0/hindcasts/GLORYS-ERA5/climatology/monthly_climatology.nc` | *(empty — no anomalies)* |

MPI from `configs/{domain}/croco_v1.3.1/myenv_frcst.sh`; `CLIM_FILE` from
`run_all_domains.yml`. `ARCHIVE_NAME` replaces today's `sed 's/...$//'` + `_`→`-` string
surgery (D11) — it silently assumes a 3-character suffix.

Together the two domains are 114 procs against a stated **120-processor ceiling**
(`run_ops_server.yml`), which is why they cannot run concurrently.

### 7.5 Downloads

| | |
|---|---|
| bbox (`--domain`) | `11,36,-39,-25` — all sources, covers both domains |
| GFS sentinel file | `${DL}/GFS/for_croco/U-component_of_wind_Y9999M1.nc` |
| MERCATOR / HYCOM output | `${DL}/{SOURCE}/{SOURCE}_{RUN_DATE}.nc` |
| saeonapps staging dir | `/home/giles/mercator_download` |
| shared mount — **write** (saeonapps) | `/mnt/somisana/data/shared/` |
| shared mount — **read** (mims3) | `/mnt/saeon-somisana/data/shared/` |

**⚠ The shared mount has different paths on the two hosts** — same share, two mount
points. Easy to get wrong when the script is meant to run identically in both places.

`for_croco` variable set (10 files, CROCO ONLINE naming; from `oceanmotion`'s `BLK_VARS`):

```
Downward_Long-Wave_Rad_Flux_Y9999M1            Specific_humidity_Y9999M1
Downward_Short-Wave_Rad_Flux_surface_Y9999M1   Temperature_height_above_ground_Y9999M1
patm_Y9999M1                                   U-component_of_wind_Y9999M1
Precipitation_rate_Y9999M1                     Upward_Long-Wave_Rad_Flux_surface_Y9999M1
V-component_of_wind_Y9999M1                    Upward_Short-Wave_Rad_Flux_surface_Y9999M1
```

### 7.6 Archive roots

With `d = ARCHIVE_NAME`, `rd = RUN_DATE`, `ym = ${rd:0:6}`, `k = ${OGCM}-${BLK}`.
**All paths hang off `PUBLIC_ROOT` / `SAFE_ROOT`** so D23's test redirection is a one-line
change:

| purpose | path |
|---|---|
| public, per cycle | `${PUBLIC_ROOT}/{d}/{VERSION}/forecasts/{rd}/{k}/` |
| public, **latest** (D7 contract) | `${PUBLIC_ROOT}/{d}/{VERSION}/forecasts/latest/{k}/` |
| long-term safe | `${SAFE_ROOT}/{d}/{VERSION}/forecasts/{ym}/{rd}/{k}/` |
| forcing, per cycle | `${PUBLIC_ROOT}/sa-forcing/{rd}/{SOURCE}/` |
| forcing, safe | `${SAFE_ROOT}/sa-forcing/{ym}/{rd}/{SOURCE}/` |
| forcing, **latest** (D20, new) | `${PUBLIC_ROOT}/sa-forcing/latest/{SOURCE}/` |

Retention today: public forecasts and `sa-forcing` at 6 days, `saeon-somisana` shared
MERCATOR at 5 days, `somisana_safe` long-term. Local `DATA_DIR` goes 5 → **8** days (D10).

### 7.7 Runtime input — `configs/{domain}/croco_v1.3.1/I99/myenv_in.sh`

`DT=60`, `DTFAST=60`, `NH_AVG=1`, `NH_HIS=24`, `NH_AVGSURF=1`, `NH_HISSURF=24`,
`NH_STA=1`, `NH_RST=6`, `T_REF=3`, `NLEVEL=1`.

`croco_fcst.in` placeholders substituted by `sed`: `DTNUM`, `DTFAST`, `NUMTIMES`,
`NUMHISSURF`, `NUMAVGSURF`, `NUMHIS`, `NUMAVG`, `RST_STEP`, `NUMRST`, `DATA_DIR`.
**Order matters** — `NUMHISSURF`/`NUMAVGSURF` must be substituted before
`NUMHIS`/`NUMAVG` or the shorter names match first.

### 7.8 Postprocess parameters — `postprocess_croco.yml`

| stage | parameters |
|---|---|
| `regrid_tier1` | `--Yorig 2000` |
| `regrid_tier2` | `--depths 0,-5,-10,-50,-100,-500,-1000` |
| `regrid_tier3` | `--fname croco_avg_t2.nc --spacing 0.02` |
| `crocplot` × 3 | `--skip_time 6`; surface (default), `--level 0` (**bottom**), `--level -100` |
| `compute_anomaly` | `--varlist temp,zeta --use_constant_clim True` |
| anomaly plots × 3 | `--var temp_anom --add_vectors False` |

Memory hints from today's docker flags: tier2 `35g`, tier3 `10g`, plots `10g`, all
`--cpus=1`.

### 7.9 Confirmed on the box (2026-08-03)

All items below were open questions when this plan was written on another machine; this
session's first login to the deployment box resolved them directly.

- **`DOWNLOAD_REPO` and `DOWNLOAD_ENV` confirmed** — `/home/somisana/code/somisana-download`
  exists (has `cli.py`), and the `download` conda env exists alongside `somisana_croco`
  (`conda env list`). §7.2 values are correct, no longer assumed.
- **`DATA_DIR` free space confirmed adequate** — `/home` is a 4.0 T filesystem with 3.2 T
  free (16% used), comfortably ahead of D10's ~270 GB / 8-day estimate. Note `somisana_safe`
  (long-term archive, `/mnt/somisana_safe`) is at 82% used, 1.9 T free — fine today, worth
  watching as retention accumulates.
- **`/home/somisana/data/TPXO10` confirmed** as the TPXO location.
- **All four mounts confirmed present and auto-mounting**: `/mnt/ocims-somisana`,
  `/mnt/saeon-somisana`, `/mnt/saws-data`, `/mnt/somisana_safe` (all `autofs` + `cifs`,
  active). `public-facing/` on `ocims-somisana` already contains `sa-west`,
  `sa-southeast`, `sa-forcing` and `opendrift` — matching §7.6's expected layout.
- **`gh` confirmed installed and authenticated** — see §3. `deploy/runbook.md` §1 does not
  need re-running on this host.

Nothing left outstanding from the original list above.

# RUNBOOK

Presenter notes for the "Ungating the Supply Chain" webinar demo. `README.md`
is what attendees read; this is what you read before and during the call.

## Pre-webinar checklist

**The day before:**

If you created a `stack/.env.local` to override ports, append
`--env-file stack/.env.local` to every plain-compose command below.

1. Wipe the stack and bring it back on the cold path, to rehearse exactly
   what an attendee will see:

   ```bash
   docker compose --env-file stack/.env -f stack/docker-compose.yml down -v
   bash setup/preflight.sh
   ```

   This gives you a pristine Act 2 state (proxy cache scan history is empty)
   and exercises the same cold-pull path attendees hit.

2. Do a full rehearsal of all three acts, either through the notebook or by
   running the act scripts directly. Confirm every beat matches the run of
   show below on the actual released images, not a local build.

3. Reset back to a clean, live-ready baseline:

   ```bash
   docker compose --env-file stack/.env -f stack/docker-compose.yml down -v
   bash setup/preflight.sh
   ```

**Day of the webinar:**

Run `bash setup/preflight.sh` once more (it's fast against warm image
layers) and confirm the three URLs it prints at the end: API, web, and
JupyterLab. Do not run a full act rehearsal on the day itself; Act 3's
age-gate approval is permanent per package and version, and you want the
live run to hit a fresh, unapproved review.

## Run of show (about 12 minutes)

Fill in "actual" during rehearsal to catch beats that run long.

| Beat | Command | Expected output | Talk line | Target | Actual |
|---|---|---|---|---|---|
| Act 1.1 cold open | `bash acts/act1-gate.sh 1` | `pip download requests` and `hf download sentence-transformers/all-MiniLM-L6-v2` both complete from cache | Nothing about the developer's workflow changed. The registry is just where packages come from now. | | 2.9s |
| Act 1.2 typosquat | `bash acts/act1-gate.sh 2` | `pip download requessts` fails with pip's generic "no matching distribution"; `curl -i` on the proxy index returns HTTP 403, `error: curation_blocked`, reason "Typosquat of requests: blocked by policy" | pip can't tell you this was policy. The registry can. | | 0.3s |
| Act 1.3 known-CVE package | `bash acts/act1-gate.sh 3` | pyyaml 5.3 published to `team-packages`, downloads 200 before the scan, scan finds CVE-2020-14343 (critical) and CVE-2020-1747, artifact auto-quarantines, download now 409 | The moment the scan completes, the artifact is held. Nobody had to act. | | 5.2s |
| *(UI)* quarantine banner | open web UI, `/repositories` -> `team-packages` -> `pyyaml` | Held banner visible on the artifact detail page | This isn't a log line, it's the state of the artifact itself. | | n/a (UI, not timed) |
| *(stretch)* on-the-record release | `bash acts/act1-gate.sh release` | Every critical/high finding acknowledged, quarantine released, download returns 200 | Releasing the hold alone isn't enough. The scan policy is a second gate; it keeps blocking until every finding is acknowledged too. | | 0.1s |
| **Act 1 total** | | | | **4:00** | **8.4s** (8.5s with the stretch beat) |
| Act 2.1 rescan + SBOM + enforcement flip | `bash acts/act2-lastmonth.sh 1` | Rescan of the cached urllib3 1.24.1 wheel returns state `vulnerable`, 12 findings (CVE-2019-11324, CVE-2019-11236, CVE-2020-26137, and others); CycloneDX SBOM returned for the same cached bytes; `PUT .../security` flips `scan_on_proxy` on; the same file that just served cleanly now returns 403 `scan_blocked` for everyone | That gate went up today. What about everything that came through before it existed? Now watch it flip: same bytes, same cache, blocked the instant we turn it on. | | 1.8s |
| Act 2.2 blast radius | `bash acts/act2-lastmonth.sh 2` | Blast-radius query on CVE-2020-14343 returns affected artifacts and repos in `team-packages`, actual downloaders, and access-based latent radius | This is the Tuesday-morning question: who has it, who pulled it, who could have. | | 0.1s |
| *(UI)* blast radius page | open web UI, `/security/blast-radius` | Same CVE data rendered in the UI | | | n/a (UI, not timed) |
| Act 2.3 quarantine-now | `bash acts/act2-lastmonth.sh 3` | Clean `requests` wheel published and downloads 200; admin quarantines it with a custom reason; download returns 409 (generic body, no reason echoed); `GET /quarantine/{id}` shows the exact reason text; release restores 200 | Not every hold starts with a scan finding. This one is just a decision, on the record. | | 0.7s |
| **Act 2 total** | | | | **4:00** | **2.6s** |
| Act 3.1 age gate | `bash acts/act3-agegate.sh 1` | `pip download` of the latest boto3 release (under 14 days old) finds nothing in the index; `curl -i` on the wheel directly returns HTTP 451, `error: age_gate_blocked`, `min_age_days: 14`, a `review_id` | xz-utils-class compromises get caught in days. This gate means you were never in the first wave. | | 1.0s |
| *(UI)* approve the review | open web UI, `/age-gate`, approve the pending review | Review moves from pending to approved | A human said yes, on the record. | | 0.1s (API fallback used instead of the UI: `ak_api POST .../age-gate/reviews/<id>/approve`) |
| Act 3.2 post-approval | `bash acts/act3-agegate.sh 2` | Same request now returns HTTP 200 | Next time, you're two weeks behind the blast before it ever reaches you. | | 0.4s |
| **Act 3 total** | | | | **3:00** | **1.5s** |

Actuals above are command execution time only (each act-script invocation
timed with `time docker exec ... bash acts/actN-*.sh <step>`, serialized
against one shared `AK_TOKEN`), measured on a warm, freshly cold-rebuilt
stack. Presenter narration, pauses, and the UI moments (quarantine banner,
blast-radius page, age-gate approval click) are all on top of these numbers
and are the bulk of the real 12 minutes; do not read this row as "the demo
takes 13 seconds."

## The three UI moments

**Act 1: the quarantine banner.** After step 3, open `/repositories` ->
`team-packages` -> `pyyaml` in the web UI. The held state is visible right
on the artifact detail page.

Important: on 1.8.0, clicking Release in the UI clears only the quarantine
hold. It does **not** restore downloads by itself, because the scan policy
is an independent gate that keeps blocking on unacknowledged critical/high
findings. If you release from the UI, you still need to run
`bash acts/act1-gate.sh release` (or acknowledge the findings some other
way) before the download actually returns 200. Simplest path during the
live run: skip the UI Release button and just run the release step, which
does both.

**Act 2: the blast radius view.** After step 2, open
`/security/blast-radius` in the web UI to show the same CVE-2020-14343 data
the API call just returned, rendered for an incident review.

**Act 3: the age-gate approval.** Between step 1 and step 2, approve the
pending review at `/age-gate` in the web UI. If the UI isn't reachable for
any reason, the API fallback printed in the script's own header is:

```bash
ak_api POST /api/v1/admin/age-gate/reviews/<id>/approve '{}'
```

## Operational gotchas

All of these were verified live this session.

- **Login rate limit.** The login endpoint rate-limits hard per IP. Every
  act script logs in once per run and reuses the token for the rest of that
  run. If you're rehearsing repeatedly, export `AK_TOKEN` yourself after
  your first login; `setup/lib.sh` checks for a preset token before logging
  in again, so you avoid tripping the limit.
- **Rescan cooldown.** The rescan endpoint has a 30 second per-repository
  cooldown. Running Act 2 step 1 twice back to back inside that window
  returns 429 `RESCAN_THROTTLED`.
- **The enforcement flip persists.** Act 2 step 1's `scan_on_proxy` flip on
  `pypi-proxy` stays on after the script finishes. Only `setup/reset.sh`
  turns it back off. This also persists into Act 3.2: the boto3 wheel that
  post-approval download serves is unaffected on the package versions this
  runbook has been tested against, but scan-on-proxy enforcement staying on
  is a general condition that could, in principle, gate a different
  package's bytes too, so do not assume it is a non-issue without checking
  if you substitute a different package or version.
- **Proxy scan state persists across `reset.sh`.** `setup/reset.sh` clears
  policy-level configuration, but scan state recorded on proxy-cached
  artifacts is not wiped. A pristine Act 2.1 (state `not_scanned` again)
  needs a full `down -v`, not just `reset.sh`.
- **Age-gate approvals are permanent per version.** There is no un-approve
  API. `setup/reset.sh` clears the review queue directly in Postgres so a
  fresh run starts unapproved again.
- **Act 3 pins its resolved package across steps.** Step 1 resolves "latest
  boto3" and writes it to `tmp/agegate-pkg`; step 2 reads that file back
  instead of re-resolving, so a new boto3 release shipping between step 1
  and step 2 can't cause a mismatch. Set `AGE_GATE_PKG=name==version` to
  override the resolution entirely.
- **Randomized upload filenames are intentional.** Act 1 and Act 2 both
  append a random build-tag segment to the filename they publish to
  `team-packages`. `team-packages` deletes are soft-deletes, so
  re-publishing the exact same path and digest after a delete would
  resurrect the old artifact row (with its old quarantine and scan history)
  instead of starting clean.
- **Rescan needs the shipped Trivy service.** The Act 2 rescan beats depend
  on the compose stack's own Trivy container. A grype-configured instance
  hits a known upstream issue on proxy rescan
  (artifact-keeper/artifact-keeper#3455); don't substitute a grype-backed
  stack for this demo.

## Human spot-checks before the webinar

These three UI views were verified against the API and the underlying data,
but never actually clicked through in a browser. Check each once before
going live:

- The quarantine banner renders correctly on the held `pyyaml` artifact
  page after Act 1 step 3.
- `/security/blast-radius` renders the CVE-2020-14343 data after Act 2 step
  2.
- `/age-gate` lists the pending review from Act 3 step 1 and its Approve
  action actually works.
- Run `demo.ipynb` top to bottom in the browser once, so the notebook path
  itself (not just the act scripts run directly) is verified before going
  live.

## Fallbacks

If you created a `stack/.env.local` to override ports, append
`--env-file stack/.env.local` to the plain-compose command below.

If the backend or web container misbehaves mid-demo, try an in-place
restart before anything more drastic:

```bash
docker compose --env-file stack/.env -f stack/docker-compose.yml restart backend web
```

If that doesn't recover it, a full `bash setup/preflight.sh` re-run is safe
and idempotent.

The only live upstream fetches in the whole demo are Act 1's PyYAML wheel
download from pythonhosted.org and Act 3's boto3 metadata lookups against
pypi.org. Everything else is served warm from the pre-seeded cache. If
either of those is slow on the day, narrate through it rather than standing
in silence.

**Buffer policy.** About one minute of slack exists across the three acts.
If it's gone by the time you reach Act 3, skip the live re-run in step 2 and
narrate the 200 instead of showing it on screen.

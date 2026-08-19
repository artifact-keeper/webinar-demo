# webinar-demo

This is the demo from the "Ungating the Supply Chain" webinar: three short acts
showing [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper)
gating a package registry in real time. It runs end to end on a laptop, with
nothing to install beyond Docker.

## Requirements

Docker Desktop. Nothing else needs to be on your machine; the demo's terminal
lives inside JupyterLab, running in a container this stack builds for you.

## Quickstart

```bash
git clone https://github.com/artifact-keeper/webinar-demo
cd webinar-demo
bash setup/preflight.sh
```

`preflight.sh` checks for `docker`, `jq`, and `curl`, pulls the pinned
images, builds the Jupyter container, brings the stack up, waits for the
backend to report healthy, and waits for a one-shot `seed` service to finish
configuring the registry and warming its caches. It prints the three URLs
you need when it's done.

Plain Compose works too, if you'd rather skip the wrapper:

```bash
docker compose --env-file stack/.env -f stack/docker-compose.yml up -d --build
```

Either way, the registry configures itself and its caches warm up
automatically: the `seed` service does that on every `up`, and it's
idempotent, so running it again is a fast no-op.

Once the stack is up, open JupyterLab at
`http://localhost:8888/lab?token=artifact-keeper-demo` and either run
`demo.ipynb` from top to bottom, or open a Terminal there and run the acts
directly:

```bash
bash acts/act1-gate.sh
bash acts/act2-lastmonth.sh
bash acts/act3-agegate.sh
```

Each act script also takes a step number (`bash acts/act1-gate.sh 2`) if you
want to run one beat at a time, which is what the notebook's cells do under
the hood.

## The three acts

**Act 1: the gate holds.** A cold open shows normal developer life is
unchanged: `pip download` and `hf download` both come back warm from the
cache. Then a typosquat package is blocked before any upstream fetch ever
happens, returning a 403 that names the policy, where pip's own error would
just look like a miss. Then a package with a known CVE is published
internally, gets scanned, and auto-quarantines the moment the scan
completes: the same download that succeeded a minute earlier now returns
409. The act ends with the artifact HELD, and closes on the record: every
critical and high finding gets acknowledged, then the hold is released, and
the download returns 200 again.

**Act 2: but what about last month?** This act turns to what was already
sitting in the cache before any policy existed. An on-demand rescan runs
against a proxy-cached wheel nobody ever evaluated, turning up a dozen known
findings on bytes that were never re-downloaded, and a CycloneDX SBOM comes
back for that same cached artifact. Flipping on scan-aware serving for the
proxy is a live, one-call change, and it immediately blocks that cached file
for every consumer. A blast-radius query against a known CVE answers who has
it, who actually pulled it, and who could have based on their access. Then a
clean artifact with no findings anywhere gets quarantined by hand, on a
stated reason, showing that a hold does not require a scan finding at all.

**Act 3: do not be there next time.** A package released within the last 14
days is invisible to pip entirely; hitting the file directly returns 451
with a pending review attached. A human approves that review, on the
record, and the same request that just 451'd now returns 200.

## URLs and ports

| Service | Default URL |
|---|---|
| API | http://localhost:8080 |
| Web UI | http://localhost:3000 |
| JupyterLab | http://localhost:8888/lab?token=artifact-keeper-demo |
| OpenSearch | http://localhost:9200 |
| Trivy | http://localhost:8090 |

If one of those ports is already taken on your machine, create a
git-ignored `stack/.env.local` with plain `KEY=value` lines to override just
the ports you need. For example, if 3000 and 8080 are both busy:

```
AK_WEB_PORT=3001
AK_API_PORT=8082
```

`stack/.env.local` is layered on top of `stack/.env` and is never committed,
so this is safe to keep local to your machine.

## Start over

To reset the registry's policies and repositories back to a clean starting
point without tearing down the stack:

```bash
bash setup/reset.sh
bash setup/preflight.sh   # or: docker compose --env-file stack/.env -f stack/docker-compose.yml up -d
```

For a fully pristine stack, wipe the volumes and rebuild from nothing:

```bash
docker compose --env-file stack/.env -f stack/docker-compose.yml down -v
bash setup/preflight.sh
```

The full wipe is the only way to see Act 2's proxy cache go back to
`not_scanned`: the scan state recorded on cached artifacts persists across
`setup/reset.sh`, since that script only clears policy-level configuration,
not proxy cache history.

## Credentials

The admin username and password in `stack/.env` are committed on purpose,
so the stack and its scripts stay in lockstep. They are throwaway demo
values; never reuse them anywhere real.

## More

- Main repo: [github.com/artifact-keeper/artifact-keeper](https://github.com/artifact-keeper/artifact-keeper)
- Docs: [artifactkeeper.com](https://artifactkeeper.com)

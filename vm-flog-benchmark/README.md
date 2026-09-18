# How to Run

```shell
cp orca.env.example orca.env   # edit TF_VAR_owner and FLOG_BINARY_PATH
orca up
orca bench    # repeatable
orca down
```

`orca run` does all three in one process. VMs are created locally with
multipass by default; set `ORCA_PROVIDER=gcp` (see Variables) to create them
in GCP instead. Use the same provider for `up`, `bench`, and `down`.

This benchmark provisions Elasticsearch, Kibana, Fleet Server, and 1-8
elastic-agent VMs — no separate load-generator VMs. On each agent VM,
[flog](https://github.com/mingrammer/flog) writes a fresh batch of log files
directly to a directory watched by a Custom Logs (`filestream`) integration,
and the benchmark measures how long Elasticsearch takes to ingest that batch.

## Varying agent count without recreating the cluster

Set `TF_VAR_agent_count=8` for `up` and `down`, then choose how many agents
run in each bench with `ACTIVE_AGENT_COUNT`:

```shell
orca up
ACTIVE_AGENT_COUNT=8 orca bench
ACTIVE_AGENT_COUNT=4 orca bench
ACTIVE_AGENT_COUNT=2 orca bench
ACTIVE_AGENT_COUNT=1 orca bench
orca down
```

The first N agent VMs generate logs and ship them; the rest have
elastic-agent stopped (they show as offline in Fleet), and the doc-count gate,
diagnostics, and metrics cover only the active agents.

## Variables

Every knob is an environment variable with a default in the `variables:`
block of `config.yaml`. Overrides are taken from, highest precedence first:

1. the process environment (`FLOG_FILE_COUNT=20 orca bench`),
2. files passed with `--env-file path` (repeatable; later files win),
3. `orca.env` in this directory, loaded automatically when present,
4. the defaults in `config.yaml`.

Env files are `KEY=VALUE` lines; `#` comments, blank lines, a leading
`export `, and matching quotes are accepted. Undeclared names such as
`TF_VAR_*` may be set there too. Copy `orca.env.example` to `orca.env`
(gitignored) and edit it instead of exporting variables in every shell.

| Variable | Default | Applied at |
|---|---|---|
| `ORCA_PROVIDER` | `multipass` | up, bench, down (must not change) |
| `TF_VAR_agent_count` | `4` | up, bench, down (must not change; 1, 2, 4, or 8) |
| `ACTIVE_AGENT_COUNT` | `4` | each bench (1 to `TF_VAR_agent_count`) |
| `FLOG_BINARY_PATH` | none, required | up |
| `ELASTIC_VERSION` | `9.6.0-SNAPSHOT` | up |
| `AGENT_VERSION` | `9.2.8` | up |
| `AGENT_METRICS_PERIOD` | `15s` | up |
| `FLOG_FILE_COUNT` | `5` | each bench |
| `FLOG_LINES_PER_FILE` | `1000` | each bench |
| `FLOG_FORMAT` | `apache_common` | each bench |

Each `summary.txt` and the JSON output list the effective value of every
variable under `variables:`. `FLOG_BINARY_PATH` is deliberately left
undeclared (not listed under `variables:` in `config.yaml`) so orca fails
fast if it isn't set, instead of silently falling back to some default.

`AGENT_METRICS_PERIOD` is how often each elastic-agent samples its own process
and pipeline metrics (the agent default is 60s). The playbook sets it through
the Agent Monitoring Policy's `overrides` as `agent.monitoring.metrics_period`,
and the `elastic-agent-metrics` step detects the period from the data.

### flog binary

flog has no prebuilt arm64 release, so instead of downloading it during
`up`, the operator supplies a binary matching the agent VMs' architecture via
`FLOG_BINARY_PATH`, and the `provision` step copies it to `/usr/local/bin/flog`
on each agent VM (`ansible.builtin.copy`, i.e. effectively `scp`). Build or
download one matching your target:

- GCP (`e2-highcpu-2` default, amd64): download a `linux_amd64` release from
  https://github.com/mingrammer/flog/releases.
- multipass on Apple Silicon (arm64): no release exists; build one with
  `go install github.com/mingrammer/flog@latest` on an arm64 host (or
  cross-compile with `GOARCH=arm64 GOOS=linux go build`).

Switching `ORCA_PROVIDER` means pointing `FLOG_BINARY_PATH` at a
matching-arch binary before the next `orca up`.

### Log burst and loops in config.yaml

Each bench, every agent VM gets `FLOG_FILE_COUNT` fresh files of
`FLOG_LINES_PER_FILE` lines each (flog's native `-p`/`--split` flag splits one
`-n` run into multiple files), written to `/var/log/flog/`, which the
`filestream` integration watches. Files are deleted and regenerated — not
appended to — on every bench, so filestream sees new inodes and re-ingests
from scratch rather than picking up stale offsets.

`config.yaml` is otherwise static YAML, but orca supports a `!repeat`
directive for generating a count-driven list, used here (as in vm-benchmark)
to size the inventory, `fleet-agent-diagnostics`, and `elastic-agent-metrics`
entries to `TF_VAR_agent_count`:

```yaml
entries: !repeat
  count: ${TF_VAR_agent_count}
  as: i
  template: "agent${i} ansible_host=${steps.infra.elastic_agent_ip_${i}} ..."
```

The `execute` phase's `es-doc-count.expected` needs
`TF_VAR_agent_count × FLOG_FILE_COUNT × FLOG_LINES_PER_FILE` — orca's
`expected:` field accepts a `*`-separated product of `${...}` references for
exactly this:

```yaml
expected: ${TF_VAR_agent_count}*${FLOG_FILE_COUNT}*${FLOG_LINES_PER_FILE}
```

`!repeat` only produces lists, so the opentofu `outputs:` mapping in `setup`
still names every per-agent output explicitly, for indices 0-7. Both tofu
modules declare the same 24 outputs and return `""` for any index at or above
`TF_VAR_agent_count`, and reject counts above 8. The warmup shell step loops
over `elastic_agent_ips`, a single space-joined output, so it needs no
per-index list at all. To go past 8 agents, add outputs for the new indices to
both `tofu/*/main.tf`, list them under `outputs:` in `config.yaml`, and raise
the `agent_count` validation bound.

### Sizing for 8 agents

- multipass: each agent VM takes 2 GB and 1 vCPU, so 8 agents plus the stack
  (8 + 6 + 2 GB) need about 32 GB of host RAM and 11 VMs. Expect the
  single-vCPU Elasticsearch VM, not the agents, to be the bottleneck.
- GCP: 8 × `e2-highcpu-2` plus the stack VMs is 24 vCPUs in one zone, which
  can hit the project's per-region E2 CPU quota or a zone stockout; see the
  zone advice under GCP below.

### Why the ingestion-completion gate is in `execute`, not `collect`

flog's burst finishes writing synchronously during `warmup` — there's no
ongoing load to run for a fixed duration the way vm-benchmark's sustained
vegeta/loggen rate does. The `execute` phase's `es-doc-count` step polls
until every expected document has arrived (or times out), so that
`elastic-agent-metrics`' measurement window (`execute.start` to
`collect.start`) spans the actual ingestion burst instead of an empty gap.

The gate itself counts documents from `warmup.start`, not `execute.start`.
Each agent VM starts elastic-agent as soon as its own flog run finishes, and
the VMs run concurrently, so the first agent is already shipping while the
others are still generating. Those early documents are timestamped before
`execute.start`; counting from there would leave the gate a few thousand
short of `expected` forever and it would time out with every document already
in Elasticsearch. The collect-phase metrics windows still start at
`execute.start` so they exclude the seconds while elastic-agent was stopped.

## GCP

Prerequisites: the Google Cloud SDK, authenticated with
`gcloud auth application-default login`, and access to the
`elastic-platform-ingest` project.

```shell
cp orca.env.example orca.env   # sets ORCA_PROVIDER=gcp; edit TF_VAR_owner and FLOG_BINARY_PATH
orca up
```

`TF_VAR_owner` is the resource name prefix and project label.
`TF_VAR_operator_cidr` is optional and defaults to your current public IP.

Resources are named `<owner>-flog-bench-*` and labelled `division=engineering`,
`org=obs`, `team=elastic-agent`, `project=<owner>`, `ephemeral=true`. A
dedicated VPC allows all traffic between the benchmark VMs and only SSH,
Elasticsearch (9200), and Kibana (5601) from `operator_cidr`. If your public IP
changes between `up` and `bench`, rerun `orca up`'s tofu step with the new
CIDR: `tofu -chdir=tofu/gcp apply -var operator_cidr=<new>/32`.

Other variables (`TF_VAR_gcp_project`, `TF_VAR_gcp_zone`, machine types, disk
sizes, images) are listed at the top of `tofu/gcp/main.tf`. The stack VMs run
Ubuntu 24.04 x86_64 on `e2-standard-4` (Elasticsearch), `e2-standard-2`
(Kibana), and `e2-medium` (Fleet Server). The agent VMs default to
`e2-highcpu-2`, 2 dedicated vCPUs and 2 GB. Every VM in this benchmark
defaults to E2 because it is GCP's broadest, most available fleet: newer or
smaller families such as T2D, C3, C4A, N2D, and N4A are faster per core but
have repeatedly failed with "does not have enough resources available" in
this project's usual zone. For arm64 agents set `TF_VAR_agent_machine_type`
to `c4a-highcpu-1` or `n4a-highcpu-1` together with
`TF_VAR_agent_image=ubuntu-os-cloud/ubuntu-2404-lts-arm64` and
`TF_VAR_agent_disk_type=hyperdisk-balanced` — these fall back to smaller
fleets, so expect more stockouts than the x86_64 E2 default — and remember to
point `FLOG_BINARY_PATH` at an arm64 binary.

Capacity stockouts are per zone and per family. All VMs stay in a single
`TF_VAR_gcp_zone` (no per-role zone override) since this benchmark measures
network latency between them; if a zone reports "does not have enough
resources available", set `TF_VAR_gcp_zone` to another zone in the region
(`us-central1-a` is the busiest; try `b`, `c`, or `f`) and rerun `orca up`
after `orca down` has removed the partial run. The playbook picks the
matching Elastic artifacts from each VM's architecture.

Always finish with `orca down`; GCP resources bill until destroyed.

## SSH and known_hosts

Ansible loads `ansible/ansible.cfg` through `ANSIBLE_CONFIG`, which orca sets
automatically when an `ansible.cfg` sits next to the playbook. That config and
`ansible/group_vars/all.yml` both point SSH at `UserKnownHostsFile=/dev/null`,
so benchmark VMs never touch `~/.ssh/known_hosts`. The warmup shell step
passes the same options explicitly.

## Multipass duplicate IPs

macOS hands out VM addresses from `/var/db/dhcpd_leases`. Every `orca up`
creates new VMs with new MAC addresses, and stale leases from old runs stay in
the file until it fills the 192.168.2.x pool. Once it is full, multipass can
report the same IP for two VMs. The tofu outputs fail fast with a
"duplicate IPs" error when this happens.

To recover, stop the VMs and clear the stale leases:

```shell
orca down
sudo rm /var/db/dhcpd_leases
```

The file is recreated on the next VM boot.

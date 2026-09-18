# How to Run

```shell
orca up
orca bench    # repeatable
orca down
```

`orca run` does all three in one process. VMs are created locally with
multipass by default; set `ORCA_PROVIDER=gcp` (see Variables) to create them
in GCP instead. Use the same provider for `up`, `bench`, and `down`.

## Variables

Every knob is an environment variable with a default in the `variables:`
block of `config.yaml`. Overrides are taken from, highest precedence first:

1. the process environment (`VEGETA_EPS=100 orca bench`),
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
| `ELASTIC_VERSION` | `9.6.0-SNAPSHOT` | up |
| `AGENT_VERSION` | `9.2.8` | up |
| `AGENT_METRICS_PERIOD` | `15s` | up |
| `VEGETA_EPS` | `500` | each bench |
| `LOGGEN_EPS` | `500` | each bench |

`TF_VAR_agent_count` is the number of elastic-agent VMs (1, 2, 4, or 8); each
gets a dedicated generator VM. It drives both the tofu modules (which
support 0-8) and config.yaml's `!repeat`-generated inventory, diagnostics,
and metrics entries — see "Loops in config.yaml" below. Like
`ORCA_PROVIDER`, it must stay the same across `up`, `bench`, and `down` for
one run.

Each `summary.txt` and the JSON output list the effective value of every
variable under `variables:`.

`AGENT_METRICS_PERIOD` is how often each elastic-agent samples its own process
and pipeline metrics (the agent default is 60s). The playbook sets it through
the Agent Monitoring Policy's `overrides` as `agent.monitoring.metrics_period`,
and the `elastic-agent-metrics` step detects the period from the data.

### Loops in config.yaml

`config.yaml` is otherwise static YAML, but orca supports a `!repeat`
directive for generating a count-driven list, used here to size the
inventory, `fleet-agent-diagnostics`, and `elastic-agent-metrics` entries
to `TF_VAR_agent_count`:

```yaml
entries: !repeat
  count: ${TF_VAR_agent_count}
  as: i
  template: "agent${i} ansible_host=${steps.infra.elastic_agent_ip_${i}} ..."
```

`count` is resolved at config-load time against declared variables/env only
(not `steps.*`/`phase.*`, which don't exist yet); each of the `count` copies
of `template` has every `${i}` (or whatever name `as` gives) replaced with
its 0-based index before the rest of the document is parsed, so every step
sees an ordinary, already-expanded list. `opentofu.outputs` and the
warmup/collect `shell` loops stay statically declared for all 8 possible
agent slots instead, since tofu already emits an empty string for indices
`>= TF_VAR_agent_count` and those steps already skip blank IPs.

### Load rates

Each agent VM has a dedicated generator VM that runs vegeta against the
agent's HAProxy and Apache at `VEGETA_EPS` requests per second (producing one
Apache and one HAProxy log line per request) and loggen at `LOGGEN_EPS` CEF
messages per second, both sent over the network to the agent VM. The warmup
step writes the rates to `/etc/default/vegeta` and `/etc/default/loggen` on
every generator VM and restarts both services, so different benches of one
run can use different rates without reprovisioning.
Edit the two lines in `orca.env` between benches, or keep one file per
profile and pass it with `--env-file`, which overrides `orca.env`:

```shell
printf 'VEGETA_EPS=500\nLOGGEN_EPS=100\n' > web-heavy.env
orca bench --env-file web-heavy.env
printf 'VEGETA_EPS=100\nLOGGEN_EPS=500\n' > cef-heavy.env
orca bench --env-file cef-heavy.env
```

vegeta is capped at 64 in-flight requests, so a rate the generator VM cannot
sustain degrades gracefully instead of exhausting memory; compare the
achieved `logs-apache.access-default` rate in the summary against
`VEGETA_EPS` times `TF_VAR_agent_count` (one generator VM is provisioned per
agent VM). A rate of `0` is not supported: the warmup gate waits for Apache
logs from every agent.

## GCP

Prerequisites: the Google Cloud SDK, authenticated with
`gcloud auth application-default login`, and access to the
`elastic-platform-ingest` project.

```shell
cp orca.env.example orca.env   # sets ORCA_PROVIDER=gcp; edit TF_VAR_owner
orca up
```

`TF_VAR_owner` is the resource name prefix and project label.
`TF_VAR_operator_cidr` is optional and defaults to your current public IP.

Resources are named `<owner>-bench-*` and labelled `division=engineering`,
`org=obs`, `team=elastic-agent`, `project=<owner>`, `ephemeral=true`. A
dedicated VPC allows all traffic between the benchmark VMs and only SSH,
Elasticsearch (9200), and Kibana (5601) from `operator_cidr`. If your public IP
changes between `up` and `bench`, rerun `orca up`'s tofu step with the new
CIDR: `tofu -chdir=tofu/gcp apply -var operator_cidr=<new>/32`.

Other variables (`TF_VAR_gcp_project`, `TF_VAR_gcp_zone`, machine types, disk
sizes, images) are listed at the top of `tofu/gcp/main.tf`. The stack VMs run
Ubuntu 24.04 x86_64 on `e2-standard-4` (Elasticsearch), `e2-standard-2`
(Kibana), and `e2-medium` (Fleet Server). The agent VMs default to
`e2-highcpu-2`, 2 dedicated vCPUs and 2 GB, the same memory as the multipass
agents. Every VM in this benchmark defaults to E2 because it is GCP's
broadest, most available fleet: newer or smaller families such as T2D, C3,
C4A, N2D, and N4A are faster per core but have repeatedly failed with "does
not have enough resources available" in this project's usual zone. Each
agent VM runs Apache and HAProxy next to elastic-agent; vegeta and loggen run
on a separate generator VM of the same spec, so load generation and
ingestion no longer compete for the same VM's CPU/memory. Only the actual
shared-core E2 shapes (`e2-medium`, `e2-small`, `e2-micro`) or a single Xeon
hyperthread such as `n1-standard-1` are too weak for the agent/generator
role — they serve only ~100 req/s and vegeta's request backlog gets
OOM-killed; `e2-highcpu-2` gets 2 full dedicated vCPUs and doesn't have that
problem. Note that agent CPU percentages are normalised per vCPU, so a
2-vCPU agent reads half the value a 1-vCPU agent shows for the same work.
For arm64 agents (and generators) set `TF_VAR_agent_machine_type` to
`c4a-highcpu-1` or `n4a-highcpu-1` together with
`TF_VAR_agent_image=ubuntu-os-cloud/ubuntu-2404-lts-arm64` and
`TF_VAR_agent_disk_type=hyperdisk-balanced` — these fall back to smaller
fleets, so expect more stockouts than the x86_64 E2 default.

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
so benchmark VMs never touch `~/.ssh/known_hosts`. The warmup and collect
shell steps pass the same options explicitly.

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

# How to Run

```shell
cp orca.env.example orca.env   # edit TF_VAR_owner, ES_*, FLOG_BINARY_PATH
orca up
orca bench    # repeatable
orca down
```

`orca run` does all three in one process. VMs are created locally with
multipass by default; set `ORCA_PROVIDER=gcp` to create them in GCP instead.
Use the same provider for `up`, `bench`, and `down`.

This benchmark provisions one VM. [flog](https://github.com/mingrammer/flog)
writes a fresh batch of log files to `/var/log/flog/`, and filebeat (a
`filestream` input on `/var/log/flog/*.log`, `output.discard`) reads them. The
benchmark measures filebeat itself: CPU, memory, and how fast the discard
output acks events. filebeat sends its own telemetry
(`monitoring.elasticsearch`) to a remote Elasticsearch you provide; there is no
local stack.

## Remote Elasticsearch

Set `ES_URL`, `ES_USER`, and `ES_PASSWORD` in `orca.env`.

- `ES_URL` needs an explicit port. filebeat defaults to `:9200` and hangs
  silently on Elastic Cloud, which serves on `:443`.
- The cluster needs `xpack.monitoring.collection.enabled: true`; otherwise it
  silently drops the data. `orca up` fails fast if the setting is off (it
  cannot tell when the user lacks permission to read cluster settings):

  ```
  PUT _cluster/settings
  {"persistent": {"xpack.monitoring.collection.enabled": true}}
  ```

- The user must be allowed to write monitoring data (`superuser` works).

Credentials stay in `orca.env`, never in `config.yaml`, because orca prints
declared variables in `summary.txt`.

## Phases

| Phase | What happens |
|---|---|
| `up` | provision the VM; install flog and filebeat (not started) |
| warmup | stop filebeat, clear files and registry, generate the whole burst with flog, start filebeat; `filebeat-wait` confirms monitoring documents arrive and the discard output is acking events |
| execute | `filebeat-wait` polls every 5s until acked events equal `FLOG_FILE_COUNT * FLOG_LINES_PER_FILE`, or 30m |
| collect | `filebeat-metrics` writes CPU, memory, and events/s TSVs and charts to the bench's results directory |

`filebeat-metrics` stops at the sample before the one that completed the
burst (`until: ${steps.gate.reachedAt}`, exclusive), so the partial final
interval doesn't skew the rates. Samples from the filebeat process that ran
before warmup are ignored.

## Variables

| Variable | Default | Applied at |
|---|---|---|
| `ORCA_PROVIDER` | `multipass` | up, bench, down (must not change) |
| `ES_URL`, `ES_USER`, `ES_PASSWORD` | none, required | up, bench |
| `FLOG_BINARY_PATH` | none, required | up |
| `FILEBEAT_TARBALL_PATH` | unset | up |
| `FILEBEAT_VERSION` | `9.5.6` | up, when no tarball is given |
| `FLOG_FILE_COUNT` | `10` | each bench |
| `FLOG_LINES_PER_FILE` | `500000` | each bench |
| `FLOG_FORMAT` | `apache_common` | each bench |

Keep the burst large. filebeat reads 100,000 lines in under 5 seconds and the
monitoring period is 5s, so a small burst leaves too few samples;
`filebeat-metrics` warns when fewer than three fall in the window.

### Your own filebeat build

Set `FILEBEAT_TARBALL_PATH` to a local `.tar.gz` (for example one built from
your branch) matching the VM's architecture. It is copied to the VM and
extracted to `/opt/filebeat`, replacing the download. The tarball's top-level
directory is stripped, so the usual `filebeat-<version>-linux-<arch>/` layout
works.

### flog binary

flog has no arm64 release, so the operator supplies a binary matching the VM's
architecture via `FLOG_BINARY_PATH`, copied to `/usr/local/bin/flog`.

- GCP (`e2-highcpu-2`, amd64): a `linux_amd64` release from
  https://github.com/mingrammer/flog/releases.
- multipass on Apple Silicon (linux/arm64):
  `GOOS=linux GOARCH=arm64 go install github.com/mingrammer/flog@latest`.

## GCP

Prerequisites: the Google Cloud SDK, authenticated with
`gcloud auth application-default login`.

Set `TF_VAR_owner` (resource name prefix) and `TF_VAR_gcp_project` in
`orca.env`. `TF_VAR_operator_cidr` defaults to your current public IP and only
SSH is opened to it. If your organisation requires labels on resources, set
`TF_VAR_labels` to a JSON map. Resources are named `<owner>-filebeat-bench-*`
and labelled `project=<owner>`, `ephemeral=true`.

The VM defaults to `e2-highcpu-2` with a 50 GB disk (the generated files take
roughly 650 MB at the default burst). Other variables are at the top of
`tofu/gcp/main.tf`. If a zone reports "does not have enough resources", set
`TF_VAR_gcp_zone` and rerun `orca up` after `orca down`.

Always finish with `orca down`; GCP resources bill until destroyed.

## SSH and known_hosts

Ansible loads `ansible/ansible.cfg` through `ANSIBLE_CONFIG`, which orca sets
automatically. That config and `ansible/group_vars/all.yml` point SSH at
`UserKnownHostsFile=/dev/null`, so benchmark VMs never touch
`~/.ssh/known_hosts`. The warmup shell step passes the same options.

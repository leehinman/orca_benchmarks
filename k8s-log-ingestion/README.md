# k8s-log-ingestion

```shell
cp orca.env.example orca.env   # set ES_URL and ES_PASSWORD
orca run
```

`orca up`, `orca bench`, and `orca down` work as well; see the orca docs.

## Variables

Settings are environment variables. `orca.env` in this directory is loaded
automatically; the process environment and `--env-file` override it, and the
`variables:` block in `config.yaml` supplies defaults.

| Variable | Default | Purpose |
|---|---|---|
| `ES_URL` | none, required | Elasticsearch endpoint the agents and orca use |
| `ES_USER` | `elastic` | Elasticsearch user |
| `ES_PASSWORD` | none, required | Elasticsearch password; keep it out of `config.yaml` |
| `AGENT_IMAGE` | `elastic-agent-9.6.0-SNAPSHOT-linux-arm64.docker.tar.gz` | docker image archive loaded into kind |

Declared variables are printed under `variables:` in each `summary.txt`, which
is why the two credentials are set only in `orca.env`.

`elastic-agent-managed-kubernetes.yml` must be generated from the Kibana Fleet
UI for the policy under test; see the comments in `config.yaml`.

# Kubernetes Metrics Explorer

A small Bash utility that discovers running Kubernetes pods exposing ports
with `metric` or `prom` in their name, temporarily port-forwards those ports,
and saves Prometheus metric declarations (`# HELP` and `# TYPE`) to local
text files.

## Requirements

- Bash 4 or newer
- `kubectl`, configured with access to the target cluster
- `curl`, `awk`, `grep`, and `mktemp`

The script does not modify Kubernetes resources. It only creates temporary
port-forward processes and a local output directory.

## Validation

Run the dependency-free validation checks from the project root:

```bash
./tests/validate.sh
```

The checks validate shell syntax and command-line error handling. A live
Kubernetes cluster is not required for these checks.

## Usage

```bash
chmod +x discover-metrics.sh
./discover-metrics.sh
```

By default, all namespaces are scanned. Use options to narrow the search:

```bash
# Scan one namespace
./discover-metrics.sh --namespace monitoring

# Scan pods matching a label selector
./discover-metrics.sh --selector 'app.kubernetes.io/name=ingress-nginx'

# Match one exact pod name
./discover-metrics.sh --name api-server-7d8f9c6b4d-x2k9m

# Match pods containing text in their names
./discover-metrics.sh --name-contains api-server

# Select a cluster context and namespace
./discover-metrics.sh --context my-production-cluster --namespace database-system

# Write results somewhere else
./discover-metrics.sh --output ./output/metrics
```

Short options are also available: `-c`, `-n`, `-l`, and `-o`. `--name` uses
Kubernetes' exact `metadata.name` field filter, while `--name-contains`
performs a case-sensitive substring match locally. Run
`./discover-metrics.sh --help` for the complete usage message.

## Output

Successful endpoints produce one file in `metrics_dump/` (or the directory
specified with `--output`) using this naming pattern:

```text
namespace_container-portname.txt
```

Only Prometheus `# HELP` and `# TYPE` lines are saved; metric sample values
are intentionally omitted.

## Limitations

- Discovery depends on container port names. Ports without `metric` or `prom`
  in their name are not queried.
- The Kubernetes identity running `kubectl` must be allowed to list and get
  pods and create pod port-forwards.
- The script tries `/metrics` over HTTP first and HTTPS second.


# Elasticsearch Resource Discipline

## Metrics Server

The kubeadm cluster initially had no Metrics API, so `kubectl top` returned:

`error: Metrics API not available`

Metrics Server v0.9.0 was installed from the official upstream manifest.

After installation, the Metrics Server pod remained NotReady because it could not scrape the kubelets. Logs showed that the kubelet serving certificates did not contain IP Subject Alternative Names (SANs), for example:

`x509: cannot validate certificate for 10.10.0.11 because it doesn't contain any IP SANs`

For this lab, Metrics Server was configured with:

`--kubelet-insecure-tls`

This keeps the connection to the kubelet over HTTPS but disables verification of the kubelet serving certificate.

This is a lab workaround. In production, the preferred solution is to issue trusted kubelet serving certificates containing the correct node IP SANs and remove `--kubelet-insecure-tls`.

## Observed resource usage

After Metrics Server became healthy:

| Resource | CPU | Memory |
|---|---:|---:|
| k8s-cp | 183m | 1270Mi |
| k8s-worker-1 | 160m | 1828Mi |
| k8s-worker-2 | 134m | 3248Mi |
| Elasticsearch `shopstack-es-default-0` | approximately 41-43m | 2696Mi |
| Kibana `shopstack-kb` | approximately 28m | 908Mi |

Worker 2 was using approximately 85% of its available memory, confirming that the Final Run cluster is resource constrained.

## Elasticsearch JVM heap

The Task 6 Elasticsearch node is configured with:

`-Xms2g -Xmx2g`

The Elasticsearch container memory limit is:

`3Gi`

Therefore, the configured JVM heap represents approximately 66.7% of the container memory limit.

This is higher than the common production guideline of allocating roughly 50% of available Elasticsearch container memory to the JVM heap.

The remaining memory is important for:

- JVM native memory
- direct buffers
- memory-mapped files
- operating-system filesystem cache
- Elasticsearch native components

The 2Gi heap in this lab is an intentional Task 6 configuration running on approximately 4Gi worker nodes, so the environment cannot follow the ideal 50% ratio without increasing container and node memory.

For a production-style configuration that keeps a 2Gi heap, a container memory allocation of roughly 4Gi or more would better preserve the approximately 50% heap principle while also leaving operational headroom.

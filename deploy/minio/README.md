# MinIO storage tool

A standalone tool and Helm chart for the KubeSphere-layer storage foundation.
It installs a distributed erasure-coded MinIO **before** kube ai hub is
installed, so that `ks-installer` and `csghub` can treat object storage as an
external dependency instead of shipping their own single-node MinIO.

This directory is independent of `ks-installer`: nothing here is imported by an
Ansible role, and the chart is not a dependency of `csghub`. Run it by hand, or
from whatever automation already prepares the nodes.

```
deploy/minio/
  minio-storage-tool.sh   # prepare / install / export / import
  chart/                  # the MinIO chart
  values-example.yaml     # a documented values file for the chart
  README.md               # this file
```

## Why a static provisioner and not a dynamic one

MinIO erasure coding only survives a disk failure if the drives of one erasure
set are actually independent. A dynamic `hostPath` provisioner such as
local-path-provisioner hands out directories on whichever node it likes, so
several "independent" volumes can end up on one physical disk, and the failure
domain silently collapses.

`prepare` therefore creates one **local PV per (node, disk) pair**, each pinned
to its node with `nodeAffinity`. The mapping is then predictable: the tool, the
chart, and the operator all agree on which disk a drive lives on. The same
StorageClass (`local-static`, provisioner `kubeaihub.io/local-static`) backs both
the MinIO drives and the JuiceFS metadata database, so those two never depend on
the storage they are themselves providing.

Consequences worth knowing up front:

- **Mount the disks first.** The tool never formats or mounts anything; it only
  describes what is already there. A disk that is not mounted makes a PV that
  never binds.
- **A PV's capacity is not flexible.** Growing a volume means adding a disk and a
  PV, not resizing one. This matches how a MinIO server pool grows anyway.
- **The drive count cannot change in place.** `replicas * volumesPerServer` is
  fixed once the pool exists. Adding drives means a new pool; changing the shape
  means reinstalling and restoring.

## Layout

The disks must be formatted and mounted before `prepare` runs. By default the
tool expects:

| Kind | Mount points | Used by |
|---|---|---|
| MinIO drives | `/mnt/minio-1` … `/mnt/minio-<n>` | MinIO `data-0` … `data-<n-1>` |
| Metadata drives | `/mnt/pg-1` … `/mnt/pg-<m>` | JuiceFS metadata database |

Both prefixes and capacities are options; the defaults are just a convention.

## Commands

### `prepare`

Designates the storage nodes and creates the StorageClass and local PVs.

```sh
./minio-storage-tool.sh prepare \
  --nodes node1,node2 \
  --minio-disks 2 \
  --minio-mount-prefix /mnt/minio \
  --minio-size 5Ti \
  --metadb-disks 1 \
  --metadb-mount-prefix /mnt/pg \
  --metadb-size 5Ti
```

It labels each node `node-role.kubernetes.io/storage=true`, taints it
`storage=true:NoSchedule`, and writes one PV per disk. Re-running is safe:
existing objects are left as they are. Add `--dry-run` to print the manifests,
and `--no-label` / `--no-taint` if the nodes are already prepared.

The taint keeps ordinary workloads off the storage nodes. Anything that needs to
run there — MinIO, the metadata database — must tolerate it, which is why
`install` passes the toleration.

### `install`

Renders the chart and installs MinIO, then creates the buckets.

```sh
./minio-storage-tool.sh install \
  --namespace kubesphere-system \
  --release ks-minio \
  --mode distributed \
  --replicas 2 \
  --volumes-per-server 2 \
  --storage-class local-static \
  --volume-size 5Ti \
  --buckets jfs,pg-backup \
  --storage-nodes node1,node2
```

`--replicas * --volumes-per-server` must be at least 4, and must not exceed the
number of PVs `prepare` created. The tool warns if the PVs are missing and the
chart refuses to render a cluster with fewer than 4 drives.

| Topology | Drives | Erasure coding | Survives |
|---|---|---|---|
| 2 nodes x 1 disk | 4 | EC:2 | 1 node (at the limit) |
| **2 nodes x 2 disks** | **4** | **EC:2** | 1 node |
| 4 nodes x 2 disks | 8 | EC:4 | 2 nodes |
| 4 nodes x 3 disks | 12 | EC:6 | 2 nodes |

Adding nodes later means editing `--replicas` and re-running `prepare` for the
new node only, then reinstalling with the larger shape.

After install, read the credentials with:

```sh
kubectl -n kubesphere-system get secret ks-minio \
  -o jsonpath='{.data.accesskey}' | base64 -d
kubectl -n kubesphere-system get secret ks-minio \
  -o jsonpath='{.data.secretkey}' | base64 -d
```

MinIO is reachable in-cluster at `ks-minio.kubesphere-system.svc:9000`. Use that
address for `common.s3.endpoint` in `cluster-configuration.yaml` and for
`global.objectStore.external.endpoint` in `csghub-charts`.

### Buckets

`--buckets` defaults to `jfs,pg-backup`, which is what the storage foundation
itself needs. The platform on top of it needs its own buckets too: each service
derives its bucket from its name, so a full install wants

```sh
--buckets jfs,pg-backup,csghub-registry,csghub-billing,csghub-server,csghub-runner,csghub-llmlog
```

The bucket list is idempotent: re-running `install` creates what is missing and
leaves existing buckets, their contents and their policies alone.

## Migrating data

`export` and `import` move all buckets between two MinIO clusters. Both run
`mc mirror` in a Job inside the cluster: the dataset is far too large to stream
through a workstation, and a Job survives a dropped SSH session.

The transfer goes **through a PVC**, not object-to-object, because the
replacement MinIO usually does not exist yet while the old one is being drained.

> The backup PVC must **not** use a JuiceFS StorageClass. Backing JuiceFS data up
> onto JuiceFS is circular: if the metadata database is what you are replacing,
> the backup would be unreadable at exactly the moment you need it. Use
> `local-static` or another independent class.

### Export

```sh
./minio-storage-tool.sh export \
  --namespace kubesphere-system \
  --release ks-minio \
  --backup-pvc minio-backup
```

Buckets land in `<mount-path>/<bucket>`. The Job verifies each bucket by
comparing object count and byte count against the source, because `mc mirror` can
exit 0 after a partial failure. It then writes:

- `manifest.tsv` — `<bucket> <objects> <bytes>`, one line per bucket. This is the
  machine-readable record `import` checks against.
- `manifest.json` — the same data, for a human.

A re-export over the same PVC updates only the buckets it copied, so the manifest
always describes what the backup actually holds.

An external S3 target works too, via `--backup-endpoint` with
`--backup-access-key` / `--backup-secret-key`. An S3 target gets no manifest: the
`mc` client cannot leave files at a bucket root, and object-to-object migration
is not the intended path.

### Import

```sh
./minio-storage-tool.sh import \
  --namespace kubesphere-system \
  --release ks-minio \
  --backup-pvc minio-backup
```

Run `prepare` and `install` on the new cluster first, so the buckets exist and
carry the right policies. `import` reads `manifest.tsv` for the bucket list,
recreates missing buckets, mirrors each one, and verifies the restored object
count and byte count against the manifest. A mismatch fails the Job.

By default `import` never deletes data in the target; pass `--remove` to make the
target an exact mirror of the backup.

### Full replacement sequence

```sh
# 1. back up the old cluster into a PVC on an independent StorageClass
./minio-storage-tool.sh export --backup-pvc minio-backup --namespace kubesphere-system

# 2. tear down the old MinIO and prepare the new storage shape
./minio-storage-tool.sh prepare --nodes n1,n2,n3,n4 --minio-disks 3 --metadb-disks 1

# 3. install the new cluster
./minio-storage-tool.sh install --replicas 4 --volumes-per-server 3 \
  --buckets jfs,pg-backup --storage-nodes n1,n2,n3,n4

# 4. restore, verifying against the manifest
./minio-storage-tool.sh import --backup-pvc minio-backup
```

## Notes and limits

- Distributed MinIO needs an odd, majority-sized set of servers available to
  write. The chart ships a `PodDisruptionBudget` at `floor(replicas/2) + 1`, so
  a node drain cannot take out quorum.
- `--versions` mirrors non-current object versions as well. The count comparison
  is skipped in that mode, because the target legitimately holds more objects
  than the source's current-version count.
- Bucket policies are not migrated. They come from the chart's `buckets` list.
- Object tags are not copied by `mc mirror`.
- The tool talks to the cluster through `kubectl`; override the binary with the
  `KUBECTL` environment variable. `MC_IMAGE` overrides the client image, which
  otherwise defaults to the tag the chart ships.

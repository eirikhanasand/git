# Forgejo streaming standby

Inspur is the sole writable Forgejo. OVH is a warm failover copy: PostgreSQL
streams continuously; repository/application files still sync every five minutes.
The standby UI and runner are stopped and have the `failover` Compose profile.
Never run both applications as independent writers against these copies.

## Deployed layout

- Primary PostgreSQL 18: `git_db`, volume `git_git_db_data`, data directory
  `/var/lib/postgresql/18/docker`; published **only** on `127.0.0.1:15432`.
- Standby: same PostgreSQL image build, volume `git_git_db_streaming`.
  The old OVH `git_git_db_data` volume is retained as a pre-migration rollback copy.
- Inspur systemd unit `forgejo-replication-tunnel.service`: makes an outbound SSH
  connection to OVH port 222 and reverse-forwards OVH `127.0.0.1:15433` to the
  primary's loopback database port. This direction avoids blocked incoming SSH
  connections to Inspur.
- OVH `forgejo-replication-proxy.socket`/`.service`: socket-activated systemd proxy
  from Docker bridge `172.26.0.1:15432` to the reverse tunnel `127.0.0.1:15433`.
  A UFW rule permits only `br-dc3f1f377f4b`, source `172.26.0.0/16`, destination
  `172.26.0.1`, TCP port 15432. No PostgreSQL port is exposed publicly. Recheck
  bridge addresses/interface names if recreating Docker networks.
- Dedicated SSH key on Inspur: `/home/hanasand/.ssh/forgejo_replication_ed25519`.
  Its authorized-key entry on OVH denies shell use and permits reverse listening
  only on `127.0.0.1:15433`. Host-key checking and connection timeouts are mandatory.
- Dedicated PostgreSQL role `forgejo_replication`: LOGIN + REPLICATION, no
  superuser privilege, SCRAM authentication restricted to primary bridge gateway
  `172.23.0.1/32`. Password is in the standby's mode-0600 `replication.pgpass`
  inside PGDATA, not in Git or the systemd unit.
- Physical replication slot `forgejo_ovh`; `max_slot_wal_keep_size=2GB` on primary.
  A sufficiently long outage can invalidate the slot, requiring a fresh base
  backup. This bound prevents an unavailable standby filling the primary disk.

`primary.yml` and `standby.yml` are fragments merged into the hosts' existing
`docker-compose.override.yml`, preserving their Forgejo security settings.

## Initial migration / reseeding

1. Hold `/tmp/forgejo-standby-sync.lock` on Inspur to exclude scheduled syncs.
   Keep it held until the new script and database are verified.
2. Configure the dedicated replication role/HBA rule and WAL retention bound.
   Merge the primary port fragment and recreate only `git_db`.
3. Install/enable the encrypted tunnel on Inspur and private proxy on OVH.
   Generate a dedicated SSH key on Inspur; transfer only its public key to OVH. Transfer the database password through
   authenticated SSH directly into a restricted file, never through logs.
4. Create a **new** empty Docker volume. Using the primary's exact PostgreSQL
   image, run `pg_basebackup --wal-method=stream --checkpoint=spread --write-recovery-conf`
   with slot `forgejo_ovh` and `--create-slot` on first creation. Use the tunnel
   address, replication role, and a mode-0600 password file. PGDATA must remain
   `/var/lib/postgresql/18/docker` to match the original cluster.
5. Preserve a stopped copy of the old database volume. Merge the standby fragment,
   stop UI/runner, and recreate only `git_db` with the seeded volume. Recreate the
   stopped UI/runner containers without starting them to apply restart/profile
   policy. Install the new sync script and wrapper.
6. Confirm `pg_is_in_recovery()`, streaming WAL receiver, active primary slot,
   matching system identifiers, and replay of a primary WAL position. Run the
   file sync, then release the lock and verify a scheduled run.

The five-minute script no longer dumps/restores a database, repairs metadata, or
restarts applications. It refuses to copy files if OVH is promoted, its app/runner
is running, or WAL is not streaming. It waits for a fixed primary WAL position
before reporting success. The separate hourly doctor remains unchanged.

## Health checks

On Inspur:

```sh
systemctl status forgejo-replication-tunnel.service
docker exec git_db psql -X -U git -d git -c "SELECT application_name,state,sync_state,pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn) AS lag_bytes FROM pg_stat_replication;"
docker exec git_db psql -X -U git -d git -c "SELECT slot_name,active,wal_status,safe_wal_size FROM pg_replication_slots;"
```

On OVH:

```sh
systemctl status forgejo-replication-proxy.socket forgejo-replication-proxy.service
docker exec git_db psql -X -U git -d git -c "SELECT pg_is_in_recovery(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn();"
docker exec git_db psql -X -U git -d git -c "SELECT status,latest_end_lsn FROM pg_stat_wal_receiver;"
```

## Planned failover

1. Fence Inspur's Forgejo application and runner so no new writes can occur.
   Do not promote while the primary can still accept writes.
2. Complete a final file sync while the primary database and tunnel are available.
   Confirm the standby replays the final primary WAL position; hold the sync lock
   so no file sync can race promotion.
3. Stop/disable the Inspur replication tunnel and OVH proxy, promote OVH using
   `SELECT pg_promote();`, then start `docker compose --profile failover up -d git runner`.
4. Verify repository reads/writes and service health before routing users to OVH.
   Ensure the primary stays fenced. Returning to Inspur requires planned reseeding
   or `pg_rewind` with its prerequisites verified; do not simply restart both.

For unplanned failover, files can be up to one synchronization interval behind
WAL. Check repository and attachment consistency before exposing the service.
Streaming replication alone does not make repository files and database changes
an atomic snapshot, and it is not a substitute for independent backups.

## Rollback

The old database volume is a stale point-in-time copy, not a current replica.
To roll back the *mechanism*, first hold the sync lock and stop the new database;
restore the previous OVH override and original volume, and restore the saved sync
script. Run a complete old-style sync from the authoritative primary before making
OVH available. Do not delete the streaming volume or old volume during rollback.

# gcp-free-agents

Terraform for one GCP e2-micro VM (Debian 12) that runs several AI agents with
docker compose. The design targets the GCP Always Free tier and isolates the
agents from each other and from the VM's credentials.

> **Not $0.** The VM's ephemeral external IPv4 is billed by the hour. At
> $0.005/hr that is about **3.6 USD/month**. **Unverified:** the rate comes from
> third-party write-ups, and the Always Free page lists no free allowance for external
> IPs. Check the current rate on the [VPC network pricing page](https://cloud.google.com/vpc/network-pricing).
> The VM needs it for outbound traffic (apt, image pulls, LLM APIs) because Cloud NAT
> costs more. The budget defaults to 5 USD so the alerts stay meaningful.

## What gets created

| File | Resources |
|---|---|
| `main.tf` | API enablement, e2-micro VM (pd-standard ≤30 GB, Shielded VM, OS Login, ephemeral external IP) |
| `network.tf` | Custom VPC + subnet, one firewall rule: IAP `35.235.240.0/20` → tcp/22 on the `<prefix>-iap-ssh` tag |
| `iam.tf` | Dedicated VM service account; logWriter + metricWriter only (`enable_ops_roles`, on by default) |
| `budget.tf` | Billing budget with alerts at 50% and 100% |
| `scripts/startup.sh` | Swap, exim4 removal, docker-ce, Docker log driver, `agent` user, metadata-server block for containers |
| `agents/docker-compose.yml` | Hardened compose template with `agent-a` and `agent-b` |
| `agents/wrapper/Dockerfile` | Wraps any agent image: uid/gid 1000 user, `/data` owned by it for the named volume |
| `Makefile` | `make check`: static checks (terraform fmt/validate, shellcheck, compose config) |

## Prerequisites

1. Install the gcloud CLI and log in:

   ```bash
   gcloud auth login
   gcloud auth application-default login   # credentials Terraform uses
   gcloud config set project <PROJECT_ID>
   ```

2. The project must be linked to a billing account. Check the account's currency with
   `gcloud billing accounts describe <BILLING_ACCOUNT_ID> --format='value(currencyCode)'`.
   If it isn't USD, set `budget_currency_code` and `budget_amount` in `terraform.tfvars`
   to match. Otherwise budget creation fails with `Error 400: Request contains an invalid argument`.

3. IAM your user needs:

   | Purpose | Role |
   |---|---|
   | Run Terraform on the project | `roles/owner`, or: `roles/compute.admin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/serviceusage.serviceUsageAdmin`, `roles/resourcemanager.projectIamAdmin` (only with `enable_ops_roles`) |
   | Create the budget | `roles/billing.costsManager` or `roles/billing.admin` **on the billing account** |
   | SSH via IAP + OS Login | `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin` (sudo; needed to run docker) |

4. APIs: Terraform enables `compute`, `iam`, `iap`, `oslogin`, `billingbudgets` and `logging`.
   Terraform needs these two to be on before it can enable anything:

   ```bash
   gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com
   ```

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in project_id / billing_account_id
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

The startup script needs a few minutes on first boot. To follow it:

```bash
$(terraform output -raw iap_ssh_command) -- 'sudo journalctl -u google-startup-scripts -f'
```

## Access the VM

```bash
scripts/ssh.sh                    # shell on the VM (IAP + OS Login)
scripts/ssh.sh 'sudo docker ps'   # one-off command
scripts/ssh.sh --bbgo             # shell inside the bbgo container
```

## Claude Code on the VM

`startup.sh` creates a `claude` user (no sudo, not in the docker group, can't read
`/opt/agents`; member of `systemd-journal` to read logs), installs `claude-code` and
`tmux` from Anthropic's signed apt repo, and runs `claude remote-control --capacity 2`
as `claude-remote.service` inside a tmux session, from `/home/claude/work`.

- **Memory:** the docs list 4 GB+ RAM; this VM has 1 GB. One light session measured
  about 390 MB (server ~140 MB + one session process ~240 MB). Each extra remote session is
  another ~200-250 MB process. `--capacity 2` allows a second session, but run only one at
  a time: two busy sessions exceed the 1 GB of RAM and go into swap. Whether an idle session
  gives its memory back is unmeasured. `MemoryHigh=700M` throttles the service instead of
  killing it; that value is an estimate, not tuned.
- **Inbound messages:** the service passes `--settings /etc/claude-remote-settings.json`
  (root-owned) with `crossSessionInbound: accept`. Without it, a bypass-mode session holds
  every message from a cloud session for manual approval. Accepted messages drive the VM's
  Claude with no approval step. Remote Control reads the file only at start, so
  `startup.sh` restarts the service when it changes. Cloud sessions can't `SendMessage`
  replies back from another machine; the PR is the reliable completion signal.
- **Restart:** `Restart=always`, because Remote Control exits after about 10 minutes offline.
- **Own tmux socket (`-L claude-rc`):** so other tmux sessions can't keep the tmux server
  alive after Remote Control exits, which would stop systemd from restarting it.

```bash
scripts/ssh.sh                                  # then on the VM:
systemctl status claude-remote                  # service state
sudo -iu claude tmux -L claude-rc attach -t claude   # see its screen (detach: Ctrl+b d)
sudo -iu claude                                 # plain shell as claude (manual `claude`, login)
journalctl -u claude-remote -e                  # service log
sudo apt-get install --only-upgrade claude-code # apt installs don't auto-update
```

**First setup on a fresh VM:** log in once (`sudo -iu claude`, run `claude`, use a
claude.ai subscription; API keys and `CLAUDE_CODE_OAUTH_TOKEN` don't work for Remote
Control, and `ANTHROPIC_API_KEY` must be unset), accept the trust prompt in `~/work`, then
`sudo systemctl restart claude-remote`. Until then the service waits for login or restarts
every 30 s. If a prompt reappears later, attach to the tmux session and answer it.

## Docker is installed but disabled

`startup.sh` disables `docker`, `docker.socket` and `containerd` on every boot to save
memory on the 1 GB VM. Before using the sections below, delete the `systemctl disable --now docker.service ...`
line in `scripts/startup.sh`, apply, and run
`sudo systemctl enable --now docker.socket docker.service` on the VM. Otherwise the next
boot turns docker off again.

## Run the agents

```bash
VM=$(terraform output -raw vm_name)
ZONE=$(terraform output -raw vm_zone)

# 1. Prepare secrets locally (agents/secrets/ is gitignored)
mkdir -p agents/secrets
cp agents/agent.env.example agents/secrets/agent-a.env
cp agents/agent.env.example agents/secrets/agent-b.env
# edit both files

# 2. Copy to your home dir on the VM over IAP
gcloud compute scp --tunnel-through-iap --zone "$ZONE" --recurse agents "$VM":~/

# 3. Move into /opt/agents (owned by the agent user) and start
gcloud compute ssh "$VM" --zone "$ZONE" --tunnel-through-iap -- '
  sudo cp -r ~/agents/. /opt/agents/ &&
  sudo chown -R agent:agent /opt/agents &&
  sudo chmod 600 /opt/agents/secrets/*.env &&
  rm -rf ~/agents &&
  cd /opt/agents && sudo docker compose up -d --build && sudo docker compose ps'
```

## Run bbgo manually

The `bbgo` service runs an image built from the bbgo repo's `Dockerfile` (a separate checkout at `../bbgo`) on your Mac.
The container stays idle; you `exec` into it and start bbgo yourself.

```bash
# 1. Build on the Mac from the bbgo checkout. amd64 is emulated on
#    Apple Silicon, so this is slow. The tag must match BASE_IMAGE in docker-compose.yml.
BBGO_DIR=../bbgo
TAG=$(git -C $BBGO_DIR rev-parse --short HEAD)
docker buildx build --platform linux/amd64 -t bbgo:$TAG --load $BBGO_DIR

# 2. Stream the image to the VM over IAP. This is ingress to GCP, so it isn't billed.
VM=$(terraform output -raw vm_name); ZONE=$(terraform output -raw vm_zone)
docker save bbgo:$TAG | gzip | gcloud compute ssh "$VM" --zone "$ZONE" --tunnel-through-iap -- 'gunzip | sudo docker load'

# 3. Configs + secrets (both dirs are gitignored)
mkdir -p agents/bbgo-config agents/secrets
cp $BBGO_DIR/bbgo.yaml agents/bbgo-config/            # any strategy configs you want available
cat > agents/secrets/bbgo.env <<'EOF'
BINANCE_API_KEY=...
BINANCE_API_SECRET=...
# for configs with `sync:` (e.g. xmaker), use sqlite on the volume:
# DB_DRIVER=sqlite3
# DB_DSN=/data/bbgo.sqlite3
EOF
```

Then copy `agents/` to the VM as in **Run the agents** step 2–3, but start only bbgo:

```bash
cd /opt/agents && sudo docker compose up -d --build bbgo
sudo docker compose exec bbgo sh
# inside the container (cwd /data, writable):
bbgo run --config /config/bbgo.yaml --no-compile
```

- The process dies when your SSH session ends. To keep it running, start it detached
  with output going to the volume, then follow the log:
  `sudo docker compose exec -d bbgo sh -c 'bbgo run --config /config/bbgo.yaml --no-compile >>/data/bbgo.log 2>&1'`
  `sudo docker compose exec bbgo tail -f /data/bbgo.log`
  Stop it with `sudo docker compose exec bbgo pkill bbgo`.
- **Exchange IP allowlist:** the ephemeral IP survives a reboot but **changes on stop/start**.
  Update the allowlist after any stop/start. Give API keys trading permission only, **no withdrawals**.
- Memory is capped at 300m like the other services. Check with `sudo docker stats bbgo`.

## Verify isolation

On the VM (`$(terraform output -raw iap_ssh_command)`):

```bash
# Rule is in place
# lines 1-3: ACCEPT udp dpt:53, ACCEPT tcp dpt:53, DROP ... 169.254.169.254
sudo iptables -L DOCKER-USER -n --line-numbers
systemctl status docker-metadata-block.service

# Container -> metadata server: must FAIL (timeout, because the rule is DROP)
sudo docker compose -f /opt/agents/docker-compose.yml exec agent-a \
  wget -q -T 5 -O- --header 'Metadata-Flavor: Google' \
  http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token
echo "exit=$?"   # non-zero expected

# Container DNS (via the metadata IP, port 53 allowed): must SUCCEED
sudo docker compose -f /opt/agents/docker-compose.yml exec agent-a nslookup example.com

# Container -> /data (named volume, owned by 1000:1000 via the wrapper): must SUCCEED
sudo docker compose -f /opt/agents/docker-compose.yml exec agent-a touch /data/ok && echo ok

# Container -> internet: must SUCCEED
sudo docker compose -f /opt/agents/docker-compose.yml exec agent-a wget -q -T 5 -O- http://example.com >/dev/null && echo ok

# Host -> metadata server: still works (the host needs it)
curl -s -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/name

# Persistence: the three rules must still be at lines 1-3 after both of these
sudo systemctl restart docker && sudo iptables -L DOCKER-USER -n
sudo reboot   # reconnect, then check again
```

The VM SA can only write logs and metrics (`enable_ops_roles`). Even if a
container got a token, it could do nothing else. Set `enable_ops_roles = false`
for an SA with no roles or scopes at all; logs then stay on the VM.

## Logs

With `enable_ops_roles = true` (default) Docker's `gcplogs` driver sends container
stdout/stderr to Cloud Logging (view them in Logs Explorer).
`docker logs` still works from a local cache of 5 × 20 MB per container, so logs
can't fill the disk. Everything an agent prints, prompts and model output included,
leaves the VM.

- **Logging mode is non-blocking.** If Cloud Logging can't keep up, Docker drops log
  lines rather than stalling the agent.
- **If `gcplogs` can't authenticate, containers fail to start**:
  `failed to initialize logging driver: ...`. Check the SA role and that the
  `logging` API is on.
- **Changing `enable_ops_roles` after deploy:** `terraform apply` updates the metadata,
  but the startup script runs only at boot. Rerun it and recreate the containers
  (existing containers keep their old log driver):

  ```bash
  sudo google_metadata_script_runner startup
  cd /opt/agents && sudo docker compose up -d --force-recreate
  ```

## What can cost money

| Item | Why |
|---|---|
| **External IPv4** | ~3.6 USD/month, whether static or ephemeral (rate Unverified, see top). Expected. |
| **Egress > 1 GB/month** | Free tier is 1 GB from North America (excluding China and Australia). Agents that pull big images or stream a lot of LLM output can go over. Image pulls are ingress (free). |
| **Wrong region** | Only `us-west1/us-central1/us-east1` are free. Validation blocks the others, but resources made outside Terraform aren't checked. |
| **Wrong disk type / size** | Only `pd-standard`, and 30 GB-months total **per project**. A second disk or snapshots will bill. |
| **Second VM** | The free e2-micro allowance is by hours per month, not per instance: two VMs use it up in half a month. |
| **Logging** | Container logs go to Cloud Logging by default. Free allowance is ~50 GiB/project/month, then ~$0.50/GiB (Unverified; check [pricing](https://cloud.google.com/stackdriver/pricing)). A runaway agent can exceed it; add a Logging exclusion filter or set `enable_ops_roles = false`. |
| **GCS backend** | Free only in US regions, STANDARD class, ≤5 GB. |

The budget **only alerts and does not stop spending.** **Check Billing → Reports
the day after going live** (filter on this project, group by SKU). Expect to see only
"External IP Charge on a Standard VM" in the first days. Check again after a week.

## Notes

- **`network_mode: host`, `privileged`, docker.sock:** never use them. Host networking skips
  the FORWARD chain, so the metadata block stops working.

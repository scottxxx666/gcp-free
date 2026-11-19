#!/usr/bin/env bash
# SSH into the agents VM through IAP, using the iap_ssh_command Terraform output.
#
#   scripts/ssh.sh                       interactive shell on the VM
#   scripts/ssh.sh 'sudo docker ps'      run one command, then exit
#   scripts/ssh.sh --bbgo                shell inside the bbgo container
#
# The first run makes gcloud generate ~/.ssh/google_compute_engine and push the
# public key to your OS Login profile.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# The output has no spaces inside its values, so word-splitting it is safe.
read -r -a ssh_cmd <<<"$(terraform -chdir="$root" output -raw iap_ssh_command)"

case "${1:-}" in
  "")
    exec "${ssh_cmd[@]}"
    ;;
  --bbgo)
    remote="cd /opt/agents && sudo docker compose exec bbgo sh"
    ;;
  *)
    remote="$*"
    ;;
esac

# -t allocates a TTY so interactive remote commands (shells, docker exec) work.
exec "${ssh_cmd[@]}" -- -t "$remote"

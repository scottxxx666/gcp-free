# Static checks for this stack. Nothing here talks to GCP.
.PHONY: check

check:
	terraform fmt -check -recursive
	terraform init -backend=false -input=false >/dev/null
	terraform validate
	for f in scripts/*.sh; do bash -n "$$f"; done
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; \
	  else echo "WARN: shellcheck not installed, skipped"; fi
	@# compose fails on missing env_file paths; validate a copy against stub secrets
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT && \
	  cp agents/docker-compose.yml "$$tmp"/ && mkdir "$$tmp"/secrets && \
	  grep -o 'secrets/[^ ]*\.env' agents/docker-compose.yml | (cd "$$tmp" && xargs touch) && \
	  docker compose -f "$$tmp"/docker-compose.yml config -q && echo "compose ok"

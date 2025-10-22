#!/bin/sh
# deploy.sh - automated, idempotent deployer for Dockerized apps to a remote Linux host
# POSIX-compatible shell script (avoid bash-only features)

# Self-chmod capability
if [ ! -x "$0" ]; then
    echo "Making script executable..."
    chmod +x "$0" || {
        echo "Failed to make script executable. Please run: chmod +x $0"
        echo "Then try again"
        exit 1
    }
    echo "Script is now executable. Running..."
    exec "$0" "$@"
fi

set -eu

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

LOGFILE="deploy_$(date +%Y%m%d).log"

log() {
  printf "%s %s\n" "$(timestamp)" "$1" | tee -a "$LOGFILE"
}

error() {
  log "ERROR: $1"
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
Interactive deployment script. Will prompt for required values unless --non-interactive is used.

Options:
  --cleanup                  Remove deployed resources on remote host (containers, nginx config, app dir)
  --repo <url>               Git repository HTTPS URL
  --pat <token>              Personal Access Token (PAT)
  --branch <name>            Git branch (default: main)
  --user <ssh-user>          Remote SSH username
  --host <ssh-host>          Remote server IP or hostname
  --key <ssh-key-path>       SSH private key path (absolute)
  --port <app-port>          Application internal container port
  --non-interactive, --yes   Run without prompts; requires required values passed as flags
  --sudo-remote              Use sudo for remote commands where needed
  --dry-run                  Print actions that would be taken without executing them
  -h, --help                 Show this help
EOF
  exit 2
}

# CLI flags (can be passed instead of interactive prompts)
cleanup_only=0
NONINTERACTIVE=0
SUDO_REMOTE=0
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cleanup)
      cleanup_only=1; shift;;
    --repo)
      GIT_URL="$2"; shift 2;;
    --pat)
      GIT_PAT="$2"; shift 2;;
    --branch)
      GIT_BRANCH="$2"; shift 2;;
    --user)
      REM_USER="$2"; shift 2;;
    --host)
      REM_HOST="$2"; shift 2;;
    --key)
      SSH_KEY="$2"; shift 2;;
    --port)
      APP_PORT="$2"; shift 2;;
    --non-interactive|--yes)
      NONINTERACTIVE=1; shift;;
    --sudo-remote)
      SUDO_REMOTE=1; shift;;
    --dry-run)
      DRY_RUN=1; shift;;
    -h|--help)
      usage; shift;;
    *)
      break;;
  esac
done

trap_on_exit() {
  rc=$?
  if [ $rc -ne 0 ]; then
    error "Script exited with code $rc"
  else
    log "Script completed successfully"
  fi
}

trap 'trap_on_exit' EXIT INT TERM

prompt_nonempty() {
  prompt="$1"
  varname="$2"
  default="${3-}"
  while :; do
    if [ -n "$default" ]; then
      printf "%s [%s]: " "$prompt" "$default"
    else
      printf "%s: " "$prompt"
    fi
    if ! read ans; then
      error "Input aborted"
      exit 3
    fi
    if [ -z "$ans" ] && [ -n "$default" ]; then
      ans="$default"
    fi
    if [ -n "$ans" ]; then
      eval "$varname='""$ans""'"
      break
    fi
  done
}

log "Starting deployment script"

# Interactive prompts only if NONINTERACTIVE is not set; otherwise rely on flags
if [ "$NONINTERACTIVE" -eq 0 ]; then
  prompt_nonempty "Git repository HTTPS URL (e.g. https://github.com/org/repo.git)" GIT_URL
  prompt_nonempty "Personal Access Token (PAT) - will not be echoed" GIT_PAT
  # ensure PAT not printed
  printf "Enter PAT (input hidden): "
  stty -echo || true
  read -r GIT_PAT_HIDDEN || true
  stty echo || true
  printf "\n"
  if [ -n "$GIT_PAT_HIDDEN" ]; then
    GIT_PAT="$GIT_PAT_HIDDEN"
  fi

  prompt_nonempty "Branch name (default: main)" GIT_BRANCH main

  prompt_nonempty "Remote SSH username" REM_USER
  prompt_nonempty "Remote server IP or hostname" REM_HOST
  prompt_nonempty "SSH private key path (absolute)" SSH_KEY
  prompt_nonempty "Application internal port (container port)" APP_PORT
else
  # Non-interactive: ensure required variables are present
  missing=0
  for var in GIT_URL GIT_PAT REM_USER REM_HOST SSH_KEY APP_PORT; do
    eval "val=\"\".$var\"\" || true"
    eval "val=\"\$$var\""
    if [ -z "${val}" ]; then
      error "Missing required flag for non-interactive mode: $var"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    error "Run with --help for usage and required flags"
    exit 2
  fi
fi

if ! [ -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
  exit 4
fi

# Normalize repo name and local dir
repo_basename=$(basename "$GIT_URL" .git)
workdir="${PWD%/}/$repo_basename"

log "Repository: $GIT_URL (branch: $GIT_BRANCH); local dir: $workdir"

if [ -d "$workdir/.git" ]; then
  log "Local repo exists — fetching latest"
  (cd "$workdir" && git fetch --all --prune) 2>&1 | tee -a "$LOGFILE"
  (cd "$workdir" && git checkout "$GIT_BRANCH") 2>&1 | tee -a "$LOGFILE"
  (cd "$workdir" && git pull origin "$GIT_BRANCH") 2>&1 | tee -a "$LOGFILE"
else
  log "Cloning repository (using PAT for authentication)"
  # Insert PAT into URL safely for git clone (avoid echoing PAT)
  auth_url=$(echo "$GIT_URL" | sed -e "s#https://##")
  clone_url="https://$GIT_PAT@$auth_url"
  git clone --depth 1 --branch "$GIT_BRANCH" "$clone_url" "$workdir" 2>&1 | tee -a "$LOGFILE" || {
    error "git clone failed"
    exit 5
  }
  # remove the PAT from the remote
  (cd "$workdir" && git remote set-url origin "$GIT_URL")
fi

cd "$workdir" || {
  error "Failed to cd into $workdir"
  exit 6
}

if [ -f Dockerfile ] || [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  log "Found Dockerfile or docker-compose in project"
else
  error "No Dockerfile or docker-compose.yml found in project"
  exit 7
fi

ssh_opts="-i $SSH_KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

log "Checking SSH connectivity to $REM_USER@$REM_HOST"
if ssh $ssh_opts "$REM_USER@$REM_HOST" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
  log "SSH connection OK"
else
  error "SSH test failed"
  exit 8
fi

remote_app_dir="~/deployments/$repo_basename"
nginx_conf="/etc/nginx/sites-available/$repo_basename.conf"
nginx_enabled="/etc/nginx/sites-enabled/$repo_basename.conf"
container_name="$repo_basename-app"

remote_run() {
  # run multiple commands on remote
  cmd="$1"
  if [ "$SUDO_REMOTE" -eq 1 ]; then
    # try to run with sudo where appropriate
    cmd="sudo sh -c \"$1\""
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] ssh $ssh_opts $REM_USER@$REM_HOST '$cmd'"
    return 0
  fi
  ssh $ssh_opts "$REM_USER@$REM_HOST" "$cmd"
}

if [ "$cleanup_only" -eq 1 ]; then
  log "Running cleanup on remote host"
  remote_run "set -e; if [ -d $remote_app_dir ]; then rm -rf $remote_app_dir; fi; if docker ps -a --format '{{.Names}}' | grep -q '^$container_name$'; then docker rm -f $container_name || true; fi; if [ -f $nginx_conf ]; then rm -f $nginx_conf; fi; if [ -f $nginx_enabled ]; then rm -f $nginx_enabled; fi; nginx -t || true; systemctl reload nginx || true"
  log "Cleanup completed"
  exit 0
fi

log "Preparing remote environment: updating packages and ensuring Docker, Docker Compose, and Nginx exist"

install_script="set -e; \
  if command -v docker >/dev/null 2>&1; then echo 'docker-ok'; else \
    if [ -f /etc/debian_version ]; then apt-get update && apt-get install -y ca-certificates curl gnupg lsb-release && curl -fsSL https://get.docker.com | sh; \
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; \
    else echo 'Unsupported package manager; please install Docker manually' && exit 10; fi; fi; \
  if command -v docker >/dev/null 2>&1; then docker --version; else echo 'docker-missing' && exit 11; fi; \
  if command -v docker-compose >/dev/null 2>&1; then docker-compose --version; elif docker compose version >/dev/null 2>&1 2>/dev/null; then docker compose version; else \
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y docker-compose-plugin; fi; fi; \
  if command -v nginx >/dev/null 2>&1; then nginx -v; else if command -v apt-get >/dev/null 2>&1; then apt-get install -y nginx; elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then yum install -y nginx || dnf install -y nginx; fi; fi; \
  # add user to docker group if needed
  if command -v docker >/dev/null 2>&1; then if [ $(id -u) -ne 0 ]; then echo 'non-root user cannot add groups remotely'; fi; fi; \
  systemctl enable --now docker || true; systemctl enable --now nginx || true;"

log "Running remote install/prepare commands"
if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] remote install script: $install_script"
else
  # optionally wrap with sudo
  if [ "$SUDO_REMOTE" -eq 1 ]; then
    ssh $ssh_opts "$REM_USER@$REM_HOST" "sudo sh -c '$install_script'" 2>&1 | tee -a "$LOGFILE" || {
      error "Remote environment preparation failed"
      exit 12
    }
  else
    ssh $ssh_opts "$REM_USER@$REM_HOST" "$install_script" 2>&1 | tee -a "$LOGFILE" || {
      error "Remote environment preparation failed"
      exit 12
    }
  fi
fi

log "Transferring project files to remote host"
if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Transfer project files to $REM_USER@$REM_HOST:$remote_app_dir (rsync or scp)"
else
  if command -v rsync >/dev/null 2>&1; then
    rsync -az -e "ssh $ssh_opts" --exclude .git ./ "$REM_USER@$REM_HOST:$remote_app_dir/" 2>&1 | tee -a "$LOGFILE" || {
      error "rsync failed"
      exit 13
    }
  else
    # fallback to scp
    tar -czf /tmp/$repo_basename.tar.gz . --exclude .git
    scp -i "$SSH_KEY" /tmp/$repo_basename.tar.gz "$REM_USER@$REM_HOST:/tmp/" || exit 14
    if [ "$SUDO_REMOTE" -eq 1 ]; then
      ssh $ssh_opts "$REM_USER@$REM_HOST" "sudo sh -c 'mkdir -p $remote_app_dir && tar -xzf /tmp/$repo_basename.tar.gz -C $remote_app_dir && rm -f /tmp/$repo_basename.tar.gz'"
    else
      ssh $ssh_opts "$REM_USER@$REM_HOST" "mkdir -p $remote_app_dir && tar -xzf /tmp/$repo_basename.tar.gz -C $remote_app_dir && rm -f /tmp/$repo_basename.tar.gz"
    fi
  fi
fi

log "Deploying application on remote host"
deploy_commands="set -e; cd $remote_app_dir; \
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then \
  if docker compose version >/dev/null 2>&1; then docker compose down || true; docker compose pull || true; docker compose up -d --remove-orphans; \
  else docker-compose down || true; docker-compose pull || true; docker-compose up -d --remove-orphans; fi; \
else \
  # Build single Dockerfile with resource limits for e2-micro
  if docker ps -a --format '{{.Names}}' | grep -q '^$container_name$'; then docker rm -f $container_name || true; fi; 
  docker build -t $container_name .; 
  docker run -d --name $container_name \
    --memory="768m" \
    --memory-swap="768m" \
    --cpus=1.5 \
    --restart unless-stopped \
    -p $APP_PORT:$APP_PORT $container_name; fi; \
  # check container
  if docker ps --format '{{.Names}}' | grep -q '^$container_name$'; then echo 'container-running'; else echo 'container-missing' && exit 20; fi; \
  "

ssh $ssh_opts "$REM_USER@$REM_HOST" "$deploy_commands" 2>&1 | tee -a "$LOGFILE" || {
  error "Remote deployment failed"
  exit 15
}
if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Skipped deployment execution"
fi

log "Configuring Nginx reverse proxy on remote host"
nginx_conf_content="server {\n    listen 80;\n    server_name $REM_HOST;\n\n    location / {\n        proxy_pass http://127.0.0.1:$APP_PORT;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n    }\n}\n"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY-RUN] Would write nginx config to $nginx_conf and reload nginx"
else
  # write nginx config; use sudo if requested
  if [ "$SUDO_REMOTE" -eq 1 ]; then
    ssh $ssh_opts "$REM_USER@$REM_HOST" "sudo sh -c 'mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled && cat > $nginx_conf <<'NGINX_EOF'
$nginx_conf_content
NGINX_EOF
 ln -sf $nginx_conf $nginx_enabled; nginx -t && systemctl reload nginx || true'"
  else
    ssh $ssh_opts "$REM_USER@$REM_HOST" "mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled && cat > $nginx_conf <<'NGINX_EOF'
$nginx_conf_content
NGINX_EOF
 ln -sf $nginx_conf $nginx_enabled; nginx -t && systemctl reload nginx || true"
  fi
fi

log "Validating deployment"
log "Checking Docker and container status on remote host"
ssh $ssh_opts "$REM_USER@$REM_HOST" "docker --version && docker ps --filter name=$container_name --format 'table {{.Names}}\t{{.Status}}' || true" 2>&1 | tee -a "$LOGFILE"

log "Testing application endpoint from remote host (curl)
"
ssh $ssh_opts "$REM_USER@$REM_HOST" "apk add --no-cache curl >/dev/null 2>&1 || true; curl -sS --fail http://127.0.0.1:$APP_PORT/ || echo 'remote-curl-fail'" 2>&1 | tee -a "$LOGFILE"

log "Testing endpoint via Nginx from local machine"
if curl -sS --fail "http://$REM_HOST/" >/dev/null 2>&1; then
  log "Remote app reachable through Nginx at http://$REM_HOST/"
else
  error "Failed to reach app through Nginx from local machine"
fi

log "Deployment finished. See $LOGFILE for details."

exit 0

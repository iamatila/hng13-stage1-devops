# deploy.sh — automated deployer for Dockerized applications

This repository contains a single POSIX-compatible shell script `deploy.sh` that automates cloning a Git repository, preparing a remote Linux server, deploying a Dockerized application, and configuring Nginx as a reverse proxy.

## What it does
- Prompts for repository URL, PAT, branch, remote SSH details, and app port
- Clones or updates the repository locally using the PAT
- Validates existence of Dockerfile or docker-compose.yml
- Connects to the remote host via SSH and installs Docker, Docker Compose, and Nginx if missing
- Transfers project files (rsync or scp fallback)
- Builds and runs the Docker container(s) (docker-compose or docker)
- Configures Nginx to reverse-proxy port 80 to the application's container port
- Validates the deployment and logs all steps to `deploy_YYYYMMDD.log`
- Supports `--cleanup` to remove deployed artifacts on the remote host

## Prerequisites
- Local machine: POSIX shell (`/bin/sh`), `git`, `rsync` (optional), `ssh`, `scp`, `curl`
- Remote machine: a modern Linux distribution with systemd (Debian/Ubuntu/CentOS/RHEL tested paths)
- A Git Personal Access Token (PAT) with repo read access for private repos
- SSH access to the remote host via a private key file

## Usage
1. Make the script executable:

```sh
chmod +x deploy.sh
```

2. Run interactively:

```sh
./deploy.sh
```

3. Non-interactive / CI usage

You can pass required values as flags to run without prompts. Example:

```sh
./deploy.sh --repo https://github.com/owner/repo.git \
	--pat <YOUR_PAT> \
	--branch main \
	--user ubuntu \
	--host 203.0.113.10 \
	--key /home/me/.ssh/id_rsa \
	--port 3000 --non-interactive
```

4. Dry-run and remote sudo

- To preview what the script will do without executing remote commands, use `--dry-run`:

```sh
./deploy.sh --repo ... --pat ... --user ... --host ... --key ... --port 3000 --non-interactive --dry-run
```

- If the remote SSH user requires `sudo` to install packages or write to system directories, pass `--sudo-remote` to wrap remote commands with sudo where appropriate:

```sh
./deploy.sh --repo ... --pat ... --user ubuntu --host ... --key ... --port 3000 --non-interactive --sudo-remote
```

You will be prompted for:
- Git repository HTTPS URL (e.g. https://github.com/owner/repo.git)
- Personal Access Token (PAT) — input is hidden
- Branch (defaults to `main`)
- Remote SSH username and host
- Path to your SSH private key (absolute)
- Internal application port (container port) — used for proxying

3. Cleanup deployed resources on remote host:

```sh
./deploy.sh --cleanup
```

## Notes and security
- The script temporarily constructs a clone URL containing the PAT to perform the initial clone. It immediately resets the remote origin URL to the original HTTPS URL to avoid storing the PAT in git config.
- Keep your PAT secret. This script avoids printing the PAT but you must ensure your machine and logs are secure.
- The script aims to be idempotent: it attempts to gracefully stop and remove previous containers before redeploying and will overwrite Nginx config for the application.
- The script uses simple Nginx configuration and does not issue real SSL certificates. You should replace the placeholder SSL steps with Certbot or your preferred CA in production.

## Troubleshooting
- If SSH fails, verify the SSH key path, permissions, and that the remote host allows key-based auth.
- If Docker install fails, check the remote host's package manager or network access to Docker install scripts.
- Check the generated `deploy_YYYYMMDD.log` for details.

## Next steps / Improvements
- Add non-interactive CLI flags for automation (CI/CD)
- Implement Let's Encrypt certificate provisioning (Certbot) with automatic renewal
- Add healthcheck retries and backoff for more robust validation
- Add tests and shellcheck linting

## License
This script is provided as-is. Review and adapt for your environment before using in production.

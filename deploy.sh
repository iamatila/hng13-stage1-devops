#!/bin/sh

#############################################
# DEVOPS DEPLOYMENT AUTOMATION SCRIPT
# POSIX-compliant - works on any Unix-like system
# Logs to file only
#############################################

# Exit on any error
set -e
set -u

#############################################
# CONFIGURATION & SETUP
#############################################

# Create log file with timestamp
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

#############################################
# LOGGING FUNCTION (FILE ONLY)
#############################################

log() {
    level="$1"
    shift
    message="$*"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
   
    # Write ONLY to log file
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
}

#############################################
# ERROR HANDLING
#############################################

cleanup() {
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log ERROR "Script failed with exit code: $exit_code"
        printf "Deployment failed. Check log file: %s\n" "$LOG_FILE"
    else
        log INFO "Deployment completed successfully"
        printf "Deployment successful. Log file: %s\n" "$LOG_FILE"
    fi
}

# Set trap to call cleanup on exit
trap cleanup EXIT

#############################################
# STEP 1: COLLECT USER INPUT
#############################################

collect_user_input() {
    log INFO "Starting parameter collection"
   
    # Git Repository URL
    printf "Enter Git Repository URL: "
    read -r REPO_URL
    if ! echo "$REPO_URL" | grep -qE '^https?://'; then
        log ERROR "Invalid URL format. Must start with http:// or https://"
        printf "Error: Invalid URL format\n"
        exit 1
    fi
    log INFO "Repository URL collected: $REPO_URL"
   
    # Personal Access Token (hidden input)
    printf "Enter Personal Access Token (PAT): "
    stty -echo
    read -r PAT
    stty echo
    printf "\n"
    if [ -z "$PAT" ]; then
        log ERROR "PAT cannot be empty"
        printf "Error: PAT is required\n"
        exit 1
    fi
    log INFO "PAT collected"
   
    # Branch name with default
    printf "Enter branch name [main]: "
    read -r BRANCH
    BRANCH=${BRANCH:-main}
    log INFO "Branch set to: $BRANCH"
   
    # SSH Username
    printf "Enter SSH username: "
    read -r SSH_USER
    if [ -z "$SSH_USER" ]; then
        log ERROR "SSH username cannot be empty"
        printf "Error: SSH username is required\n"
        exit 1
    fi
    log INFO "SSH username: $SSH_USER"
   
    # Server IP
    printf "Enter server IP address: "
    read -r SERVER_IP
    if ! echo "$SERVER_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        log ERROR "Invalid IP address format"
        printf "Error: Invalid IP format\n"
        exit 1
    fi
    log INFO "Server IP: $SERVER_IP"
   
    # SSH Key Path
    printf "Enter SSH key path: "
    read -r SSH_KEY_PATH
    # Expand ~ to home directory
    case "$SSH_KEY_PATH" in
        ~*)
            SSH_KEY_PATH="$HOME${SSH_KEY_PATH#\~}"
            ;;
    esac
   
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log ERROR "SSH key not found at: $SSH_KEY_PATH"
        printf "Error: SSH key not found\n"
        exit 1
    fi
   
    # Check SSH key permissions
    KEY_PERMS=$(ls -l "$SSH_KEY_PATH" | awk '{print $1}')
    if [ "$KEY_PERMS" != "-r--------" ] && [ "$KEY_PERMS" != "-r--r--r--" ]; then
        log WARN "SSH key permissions need adjustment. Setting to 600"
        chmod 600 "$SSH_KEY_PATH"
    fi
    log INFO "SSH key validated: $SSH_KEY_PATH"
   
    # Application Port
    printf "Enter application port: "
    read -r APP_PORT
    if ! echo "$APP_PORT" | grep -qE '^[0-9]+$'; then
        log ERROR "Port must be a number"
        printf "Error: Port must be numeric\n"
        exit 1
    fi
    log INFO "Application port: $APP_PORT"
   
    log INFO "All parameters collected successfully"
}

#############################################
# STEP 2: CLONE REPOSITORY
#############################################

clone_repository() {
    log INFO "Starting repository clone"
   
    # Extract repo name from URL
    REPO_NAME=$(basename "$REPO_URL" .git)
    log INFO "Repository name: $REPO_NAME"
   
    # Check if repo already exists
    if [ -d "$REPO_NAME" ]; then
        log WARN "Repository directory already exists: $REPO_NAME"
        log INFO "Attempting to pull latest changes"
       
        cd "$REPO_NAME"
       
        # Checkout the specified branch
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
        log INFO "Checked out branch: $BRANCH"
       
        # Pull latest changes
        if git pull origin "$BRANCH" >> "../$LOG_FILE" 2>&1; then
            log INFO "Successfully pulled latest changes"
        else
            log ERROR "Failed to pull latest changes"
            exit 1
        fi
    else
        log INFO "Cloning repository from: $REPO_URL"
       
        # Clone with PAT authentication
        CLONE_URL=$(echo "$REPO_URL" | sed "s|https://|https://$PAT@|")
       
        if git clone -b "$BRANCH" "$CLONE_URL" "$REPO_NAME" >> "$LOG_FILE" 2>&1; then
            log INFO "Repository cloned successfully"
            cd "$REPO_NAME"
        else
            log ERROR "Failed to clone repository"
            exit 1
        fi
    fi
   
    log INFO "Current working directory: $(pwd)"
}

#############################################
# STEP 3: VERIFY DOCKERFILE
#############################################

verify_dockerfile() {
    log INFO "Verifying Docker configuration files"
   
    if [ -f "Dockerfile" ]; then
        log INFO "Dockerfile found"
        DOCKER_MODE="dockerfile"
    elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log INFO "docker-compose.yml found"
        DOCKER_MODE="compose"
    else
        log ERROR "No Dockerfile or docker-compose.yml found in repository"
        printf "Error: Missing Docker configuration\n"
        exit 1
    fi
   
    log INFO "Docker mode set to: $DOCKER_MODE"
}

#############################################
# STEP 4: TEST SSH CONNECTION
#############################################

test_ssh_connection() {
    log INFO "Testing SSH connection to $SSH_USER@$SERVER_IP"
   
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo 'SSH test successful'" >> "../$LOG_FILE" 2>&1; then
        log INFO "SSH connection test passed"
    else
        log ERROR "SSH connection failed"
        log ERROR "Verify: IP address, SSH key, username, server availability"
        printf "Error: Cannot connect to server via SSH\n"
        exit 1
    fi
}

#############################################
# STEP 5: PREPARE REMOTE SERVER
#############################################

prepare_remote_server() {
    log INFO "Preparing remote server environment"
   
    log INFO "Updating system packages on remote server"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sh -s' >> "../$LOG_FILE" 2>&1 <<'ENDSSH'
set -e
sudo apt-get update -y
printf "System packages updated\n"
ENDSSH
    log INFO "System packages updated successfully"
   
    log INFO "Installing Docker on remote server"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sh -s' >> "../$LOG_FILE" 2>&1 <<'ENDSSH'
set -e

if ! command -v docker >/dev/null 2>&1; then
    printf "Installing Docker...\n"
   
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    printf "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\n" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
   
    printf "Docker installed\n"
else
    printf "Docker already installed\n"
fi

sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER

docker --version
ENDSSH
    log INFO "Docker installation completed"
   
    log INFO "Installing Docker Compose on remote server"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sh -s' >> "../$LOG_FILE" 2>&1 <<'ENDSSH'
set -e

if ! command -v docker-compose >/dev/null 2>&1; then
    printf "Installing Docker Compose...\n"
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    printf "Docker Compose installed\n"
else
    printf "Docker Compose already installed\n"
fi

docker-compose --version
ENDSSH
    log INFO "Docker Compose installation completed"
   
    log INFO "Installing Nginx on remote server"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sh -s' >> "../$LOG_FILE" 2>&1 <<'ENDSSH'
set -e

if ! command -v nginx >/dev/null 2>&1; then
    printf "Installing Nginx...\n"
    sudo apt-get install -y nginx
    printf "Nginx installed\n"
else
    printf "Nginx already installed\n"
fi

sudo systemctl start nginx
sudo systemctl enable nginx

nginx -v
ENDSSH
    log INFO "Nginx installation completed"
   
    log INFO "Remote server preparation completed successfully"
}

#############################################
# STEP 6: DEPLOY DOCKERIZED APPLICATION
#############################################

deploy_application() {
    log INFO "===== STARTING APPLICATION DEPLOYMENT ====="
   
    # Get current directory (the cloned repo)
    LOCAL_DIR="../hng13-stage1-devops"
    # LOCAL_DIR=$(pwd)
    REMOTE_DIR="/home/$SSH_USER/app"
   
    log INFO "Transferring files to remote server"
    log INFO "Local directory: $LOCAL_DIR"
    log INFO "Remote directory: $REMOTE_DIR"
   
    # Create remote directory
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR" >> "../$LOG_FILE" 2>&1
    log INFO "Remote directory created"

    # echo "LOCAL_DIR: $LOCAL_DIR"
    # echo "REMOTE_DIR: $REMOTE_DIR"
    # echo "SSH_USER: $SSH_USER"
    # echo "SERVER_IP: $SERVER_IP"
    # echo "SSH_KEY_PATH: $SSH_KEY_PATH"
   
    # Transfer files using rsync
    if rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        --exclude='.git' \
        "$LOCAL_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_DIR/" >> "../$LOG_FILE" 2>&1; then
        log INFO "Files transferred successfully"
    else
        log ERROR "Failed to transfer files"
        exit 1
    fi
    # if rsync -avz -e "ssh -i '$SSH_KEY_PATH' -o StrictHostKeyChecking=no" \
    #     --exclude='.git' \
    #     "$LOCAL_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_DIR/" >> "../$LOG_FILE" 2>&1; then
    #     log INFO "Files transferred successfully"
    # else
    #     log ERROR "Failed to transfer files"
    #     exit 1
    # fi
   
    # Stop and remove old container if exists (idempotency)
    log INFO "Checking for existing containers"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" sh -s >> "../$LOG_FILE" 2>&1 <<ENDSSH
if docker ps -a | grep -q my-app; then
    printf "Stopping and removing old container...\n"
    docker stop my-app 2>/dev/null || true
    docker rm my-app 2>/dev/null || true
    printf "Old container removed\n"
else
    printf "No existing container found\n"
fi
ENDSSH
    log INFO "Cleanup completed"
   
    # Build and run Docker container
    log INFO "Building and running Docker container"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" sh -s >> "../$LOG_FILE" 2>&1 <<ENDSSH
cd $REMOTE_DIR

# Build Docker image
printf "Building Docker image...\n"
docker build -t my-app:latest .

# Run container
printf "Starting container...\n"
docker run -d \
    --name my-app \
    --restart unless-stopped \
    -p $APP_PORT:80 \
    my-app:latest

printf "Container started successfully\n"
ENDSSH
    log INFO "Docker container deployed"
   
    # Wait for container to be ready
    log INFO "Waiting for container to be healthy..."
    sleep 5
   
    # Verify container is running
    log INFO "Verifying container status"
    CONTAINER_STATUS=$(ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "docker ps -f name=my-app --format '{{.Status}}'")
    log INFO "Container status: $CONTAINER_STATUS"
   
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "docker ps | grep -q my-app"; then
        log INFO "Container is running successfully"
    else
        log ERROR "Container failed to start"
        log ERROR "Checking container logs..."
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "docker logs my-app" >> "../$LOG_FILE" 2>&1
        exit 1
    fi
}

#############################################
# STEP 7: CONFIGURE NGINX REVERSE PROXY
#############################################

configure_nginx() {
    log INFO "===== CONFIGURING NGINX REVERSE PROXY ====="
   
    log INFO "Creating Nginx configuration"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" sh -s >> "../$LOG_FILE" 2>&1 <<ENDSSH
# Remove default config if exists
sudo rm -f /etc/nginx/sites-enabled/default

# Create new config
sudo sh -c "cat > /etc/nginx/sites-available/my-app" <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Create symbolic link
sudo ln -sf /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/my-app

printf "Nginx configuration created\n"
ENDSSH
    log INFO "Nginx configuration file created"
   
    # Test Nginx configuration
    log INFO "Testing Nginx configuration"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo nginx -t" >> "../$LOG_FILE" 2>&1; then
        log INFO "Nginx configuration test passed"
    else
        log ERROR "Nginx configuration test failed"
        exit 1
    fi
   
    # Reload Nginx
    log INFO "Reloading Nginx"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo systemctl reload nginx" >> "../$LOG_FILE" 2>&1
    log INFO "Nginx reloaded successfully"
}

#############################################
# STEP 8: VALIDATE DEPLOYMENT
#############################################

validate_deployment() {
    log INFO "===== VALIDATING DEPLOYMENT ====="
   
    # Check Docker service
    log INFO "Checking Docker service status"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "systemctl is-active docker" >> "../$LOG_FILE" 2>&1; then
        log INFO "Docker service is running"
    else
        log ERROR "Docker service is not running"
        exit 1
    fi
   
    # Check container health
    log INFO "Checking container health"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "docker ps -f name=my-app -f status=running | grep -q my-app"; then
        log INFO "Container is healthy and running"
    else
        log ERROR "Container is not running"
        exit 1
    fi
   
    # Check Nginx status
    log INFO "Checking Nginx service status"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "systemctl is-active nginx" >> "../$LOG_FILE" 2>&1; then
        log INFO "Nginx service is running"
    else
        log ERROR "Nginx service is not running"
        exit 1
    fi
   
    # Test local endpoint on server
    log INFO "Testing application endpoint locally on server"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "curl -f -s http://localhost:$APP_PORT" >> "../$LOG_FILE" 2>&1; then
        log INFO "Application responds correctly on port $APP_PORT"
    else
        log WARN "Application may not be responding correctly on port $APP_PORT"
    fi
   
    # Test Nginx proxy
    log INFO "Testing Nginx reverse proxy"
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "curl -f -s http://localhost" >> "../$LOG_FILE" 2>&1; then
        log INFO "Nginx reverse proxy is working correctly"
    else
        log WARN "Nginx reverse proxy may not be working correctly"
    fi
   
    # Test from outside (public IP)
    log INFO "Testing external access"
    if curl -f -s -m 10 "http://$SERVER_IP" >> "../$LOG_FILE" 2>&1; then
        log INFO "Application is accessible from external network"
        printf "\n"
        printf "Application successfully deployed!\n"
        printf "Access your app at: http://%s\n" "$SERVER_IP"
    else
        log WARN "Application may not be accessible from external network"
        log WARN "This could be due to firewall rules or security groups"
        printf "\n"
        printf "Deployment completed but external access needs verification\n"
        printf "Check your firewall/security group settings\n"
        printf "Try accessing: http://%s\n" "$SERVER_IP"
    fi
   
    log INFO "===== VALIDATION COMPLETED ====="
}

#############################################
# CLEANUP FUNCTION (OPTIONAL)
#############################################

cleanup_deployment() {
    log INFO "===== CLEANING UP DEPLOYMENT ====="
   
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" sh -s >> "../$LOG_FILE" 2>&1 <<'ENDSSH'
# Stop and remove container
if docker ps -a | grep -q my-app; then
    docker stop my-app
    docker rm my-app
    printf "Container removed\n"
fi

# Remove image
if docker images | grep -q my-app; then
    docker rmi my-app:latest
    printf "Image removed\n"
fi

# Remove Nginx config
sudo rm -f /etc/nginx/sites-enabled/my-app
sudo rm -f /etc/nginx/sites-available/my-app
sudo systemctl reload nginx
printf "Nginx config removed\n"

# Remove application directory
rm -rf /home/$USER/app
printf "Application files removed\n"

printf "Cleanup completed\n"
ENDSSH
   
    log INFO "Cleanup completed successfully"
    printf "All deployed resources have been removed\n"
}

#############################################
# MAIN EXECUTION
#############################################

main() {
    # Check for cleanup flag
    if [ "${1:-}" = "--cleanup" ]; then
        printf "Running cleanup mode...\n"
        log INFO "===== CLEANUP MODE ====="
       
        # Still need connection details for cleanup
        printf "Enter SSH username: "
        read -r SSH_USER
        printf "Enter server IP address: "
        read -r SERVER_IP
        printf "Enter SSH key path: "
        read -r SSH_KEY_PATH
        case "$SSH_KEY_PATH" in
            ~*)
                SSH_KEY_PATH="$HOME${SSH_KEY_PATH#\~}"
                ;;
        esac
       
        cleanup_deployment
        exit 0
    fi
   
    printf "DevOps Deployment Script Starting...\n"
    printf "All actions will be logged to: %s\n\n" "$LOG_FILE"
   
    log INFO "===== DEPLOYMENT STARTED ====="
    log INFO "Script version: 1.0 (POSIX-compliant)"
    log INFO "Execution started at: $(date)"
   
    # Phase 1: Setup
    collect_user_input
    clone_repository
    verify_dockerfile
    test_ssh_connection
    prepare_remote_server
   
    log INFO "===== PHASE 1 COMPLETED ====="
   
    # Phase 2: Deployment
    deploy_application
    configure_nginx
   
    log INFO "===== PHASE 2 COMPLETED ====="
   
    # Phase 3: Validation
    validate_deployment
   
    log INFO "===== DEPLOYMENT FULLY COMPLETED ====="
    log INFO "Execution finished at: $(date)"
   
    printf "\nDeployment log saved to: %s\n" "$LOG_FILE"
}

# Run main function with arguments
main "$@"

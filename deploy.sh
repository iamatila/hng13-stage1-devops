# #!/bin/bash

# # Automated Deployment Script
# set -e

# # Colors for output
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# BLUE='\033[0;34m'
# NC='\033[0m'

# log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
# log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
# log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
# log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# # Get user input with validation
# get_user_input() {
#     while true; do
#         printf "Enter Git repository URL: "
#         read -r GIT_REPO_URL
#         if [[ "$GIT_REPO_URL" =~ ^https?:// ]]; then
#             break
#         else
#             log_error "Invalid URL format"
#         fi
#     done

#     while true; do
#         printf "Enter Personal Access Token: "
#         stty -echo
#         read -r GIT_TOKEN
#         stty echo
#         printf "\n"
#         [ -n "$GIT_TOKEN" ] && break
#         log_error "Token cannot be empty"
#     done

#     printf "Enter SSH username: "
#     read -r SSH_USERNAME

#     while true; do
#         printf "Enter Server IP address: "
#         read -r SERVER_IP
#         if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
#             break
#         else
#             log_error "Invalid IP format"
#         fi
#     done

#     while true; do
#         printf "Enter SSH key path: "
#         read -r SSH_KEY_PATH
        
#         # Expand tilde to home directory
#         SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        
#         if [ -f "$SSH_KEY_PATH" ]; then
#             chmod 600 "$SSH_KEY_PATH"
#             break
#         else
#             log_error "SSH key not found at: $SSH_KEY_PATH"
#             log_error "Please check the path and try again"
#         fi
#     done

#     while true; do
#         printf "Enter application port: "
#         read -r APP_PORT
#         if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -gt 0 ] && [ "$APP_PORT" -lt 65536 ]; then
#             break
#         else
#             log_error "Port must be between 1-65535"
#         fi
#     done

#     printf "Enter domain name: "
#     read -r DOMAIN_NAME

#     printf "Enter Git branch (default: main): "
#     read -r GIT_BRANCH
#     GIT_BRANCH=${GIT_BRANCH:-main}
# }

# # Setup repository
# setup_repo() {
#     local repo_name=$(basename "$GIT_REPO_URL" .git)
    
#     if [ -d "$repo_name" ]; then
#         log_info "Updating existing repository..."
#         cd "$repo_name"
#         git checkout "$GIT_BRANCH"
#         git pull origin "$GIT_BRANCH" || { log_error "Pull failed"; return 1; }
#     else
#         log_info "Cloning repository..."
#         local auth_url="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
#         git clone -b "$GIT_BRANCH" "$auth_url" || { log_error "Clone failed"; return 1; }
#         cd "$repo_name"
#     fi

#     [ -f "Dockerfile" ] || { log_error "Dockerfile missing"; return 1; }
#     log_success "Repository ready"
# }

# # Test connection
# test_connection() {
#     log_info "Testing connection..."
#     ping -c 2 "$SERVER_IP" >/dev/null 2>&1 || log_warning "Ping failed"
    
#     ssh -o ConnectTimeout=10 -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
#         echo 'SSH connection successful'
#     " || { log_error "SSH failed"; return 1; }
# }

# # Setup server
# setup_server() {
#     log_info "Setting up server..."
#     ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
#         sudo apt-get update
#         sudo apt-get install -y docker.io nginx rsync
#         sudo systemctl enable docker nginx
#         sudo systemctl start docker nginx
#         sudo usermod -aG docker \$USER
        
#         # Create app directory
#         mkdir -p ~/app
        
#         echo 'Server setup complete'
#     " || { log_error "Server setup failed"; return 1; }
# }

# # Transfer files to server
# transfer_files() {
#     local repo_name=$(basename "$(pwd)")
    
#     log_info "Transferring files to server..."
    
#     # Use rsync to transfer project files (excluding .git)
#     rsync -avz --delete \
#         --exclude='.git' \
#         --exclude='node_modules' \
#         --exclude='__pycache__' \
#         --exclude='*.pyc' \
#         -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
#         ./ "${SSH_USERNAME}@${SERVER_IP}:~/app/" || { 
#         log_error "File transfer failed"; 
#         return 1; 
#     }
    
#     log_success "Files transferred successfully"
# }

# # Deploy application
# deploy_app() {
#     local repo_name=$(basename "$(pwd)")
    
#     log_info "Deploying application..."
    
#     # Create deployment script
#     cat > deploy_remote.sh << EOF
# #!/bin/bash
# set -e

# cd ~/app

# # Cleanup old container
# docker stop ${repo_name}-container 2>/dev/null || true
# docker rm ${repo_name}-container 2>/dev/null || true

# # Remove old image
# docker rmi ${repo_name}:latest 2>/dev/null || true

# # Build and run
# docker build -t ${repo_name}:latest .
# docker run -d --name ${repo_name}-container -p 127.0.0.1:${APP_PORT}:${APP_PORT} ${repo_name}:latest

# echo 'Container deployed'
# EOF

#     # Create nginx config
#     cat > nginx_${repo_name}.conf << EOF
# server {
#     listen 80;
#     server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};
    
#     location / {
#         proxy_pass http://127.0.0.1:${APP_PORT};
#         proxy_set_header Host \$host;
#         proxy_set_header X-Real-IP \$remote_addr;
#         proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto \$scheme;
#     }
    
#     location /.well-known/acme-challenge/ {
#         root /var/www/html;
#     }
# }
# EOF

#     # Transfer deployment files
#     scp -i "$SSH_KEY_PATH" deploy_remote.sh nginx_${repo_name}.conf "${SSH_USERNAME}@${SERVER_IP}:/tmp/" || {
#         log_error "Failed to transfer deployment files"
#         return 1
#     }

#     # Execute deployment
#     ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
#         cd /tmp
#         chmod +x deploy_remote.sh
#         bash deploy_remote.sh
        
#         # Configure nginx
#         sudo cp nginx_${repo_name}.conf /etc/nginx/sites-available/${repo_name}
#         sudo ln -sf /etc/nginx/sites-available/${repo_name} /etc/nginx/sites-enabled/
#         sudo rm -f /etc/nginx/sites-enabled/default
#         sudo nginx -t && sudo systemctl reload nginx
        
#         # Cleanup
#         rm -f deploy_remote.sh nginx_${repo_name}.conf
        
#         echo 'Nginx configured'
#     " || { log_error "Deployment failed"; return 1; }

#     # Cleanup local files
#     rm -f deploy_remote.sh nginx_${repo_name}.conf
    
#     log_success "Application deployed"
# }

# # Verify deployment
# verify_deployment() {
#     local repo_name=$(basename "$(pwd)")
    
#     log_info "Verifying deployment..."
#     ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
#         # Check container
#         if docker ps | grep ${repo_name}-container; then
#             echo 'Container is running'
#         else
#             echo 'Container not running'
#             docker ps -a | grep ${repo_name}-container || true
#             exit 1
#         fi
        
#         # Check nginx
#         if sudo systemctl is-active nginx >/dev/null 2>&1; then
#             echo 'Nginx is active'
#         else
#             echo 'Nginx not active'
#             exit 1
#         fi
        
#         # Health check
#         echo 'Waiting for application to start...'
#         sleep 5
        
#         if curl -f -s http://localhost:${APP_PORT} >/dev/null; then
#             echo 'Application health check passed'
#         else
#             echo 'Application health check failed - checking logs...'
#             docker logs ${repo_name}-container --tail 50
#             exit 1
#         fi
#     " || { log_error "Verification failed"; return 1; }
# }

# # Main function
# main() {
#     log_info "Starting deployment process..."
    
#     get_user_input
#     setup_repo
#     test_connection
#     setup_server
#     transfer_files  # THIS WAS MISSING!
#     deploy_app
#     verify_deployment
    
#     log_success "Deployment completed successfully!"
#     log_info "Access your application at: http://${DOMAIN_NAME}"
#     log_info "Also accessible at: http://${SERVER_IP}"
# }

# main "$@"

#!/bin/bash

# Automated Deployment Script
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get user input with validation
get_user_input() {
    while true; do
        printf "Enter Git repository URL: "
        read -r GIT_REPO_URL
        if [[ "$GIT_REPO_URL" =~ ^https?:// ]]; then
            break
        else
            log_error "Invalid URL format"
        fi
    done

    while true; do
        printf "Enter Personal Access Token: "
        stty -echo
        read -r GIT_TOKEN
        stty echo
        printf "\n"
        [ -n "$GIT_TOKEN" ] && break
        log_error "Token cannot be empty"
    done

    printf "Enter SSH username: "
    read -r SSH_USERNAME

    while true; do
        printf "Enter Server IP address: "
        read -r SERVER_IP
        if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            log_error "Invalid IP format"
        fi
    done

    while true; do
        printf "Enter SSH key path: "
        read -r SSH_KEY_PATH
        
        # Expand tilde to home directory
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        
        if [ -f "$SSH_KEY_PATH" ]; then
            chmod 600 "$SSH_KEY_PATH"
            break
        else
            log_error "SSH key not found at: $SSH_KEY_PATH"
            log_error "Please check the path and try again"
        fi
    done

    while true; do
        printf "Enter application port (recommended: 3000-9000, avoid 80/443): "
        read -r APP_PORT
        if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -gt 1024 ] && [ "$APP_PORT" -lt 65536 ]; then
            break
        elif [ "$APP_PORT" -eq 80 ] || [ "$APP_PORT" -eq 443 ]; then
            log_error "Ports 80 and 443 are reserved for Nginx. Please choose a port above 1024 (e.g., 3000, 8080)"
        else
            log_error "Port must be between 1025-65535"
        fi
    done

    printf "Enter domain name: "
    read -r DOMAIN_NAME

    printf "Enter Git branch (default: main): "
    read -r GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
}

# Setup repository
setup_repo() {
    local repo_name=$(basename "$GIT_REPO_URL" .git)
    
    if [ -d "$repo_name" ]; then
        log_info "Updating existing repository..."
        cd "$repo_name"
        git checkout "$GIT_BRANCH"
        git pull origin "$GIT_BRANCH" || { log_error "Pull failed"; return 1; }
    else
        log_info "Cloning repository..."
        local auth_url="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
        git clone -b "$GIT_BRANCH" "$auth_url" || { log_error "Clone failed"; return 1; }
        cd "$repo_name"
    fi

    if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
        log_error "Neither Dockerfile nor docker-compose.yml found"
        return 1
    fi
    
    log_success "Repository ready"
}

# Test connection
test_connection() {
    log_info "Testing connection..."
    ping -c 2 "$SERVER_IP" >/dev/null 2>&1 || log_warning "Ping failed (might be blocked by firewall)"
    
    # Test SSH with timeout
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "echo 'SSH connection successful'" 2>/dev/null; then
        log_error "SSH connection failed. Checking common issues..."
        log_error "1. Verify SSH key permissions: chmod 600 $SSH_KEY_PATH"
        log_error "2. Verify server allows key-based authentication"
        log_error "3. Try manual connection: ssh -i $SSH_KEY_PATH ${SSH_USERNAME}@${SERVER_IP}"
        return 1
    fi
    
    log_success "SSH connection successful"
}

# Setup server
setup_server() {
    log_info "Setting up server..."
    
    # First, check if Docker is already installed
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USERNAME}@${SERVER_IP}" bash <<'ENDSSH'
        set -e
        
        echo "[INFO] Updating package lists..."
        sudo apt-get update -qq
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "[INFO] Installing Docker..."
            
            # Remove old Docker packages
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            
            # Install prerequisites
            sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
            
            # Add Docker's official GPG key
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # Set up Docker repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker
            sudo apt-get update -qq
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io
            
            echo "[SUCCESS] Docker installed"
        else
            echo "[INFO] Docker already installed: $(docker --version)"
        fi
        
        # Install Nginx and rsync
        echo "[INFO] Installing Nginx and rsync..."
        sudo apt-get install -y nginx rsync
        
        # Enable and start services
        sudo systemctl enable docker nginx
        sudo systemctl start docker
        sudo systemctl start nginx
        
        # Add user to docker group
        sudo usermod -aG docker $USER
        
        # Create app directory
        mkdir -p ~/app
        
        echo "[SUCCESS] Server setup complete"
ENDSSH
    
    if [ $? -ne 0 ]; then
        log_error "Server setup failed"
        return 1
    fi
    
    log_success "Server setup completed"
}

# Transfer files to server
transfer_files() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Transferring files to server..."
    
    # Create remote directory
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USERNAME}@${SERVER_IP}" \
        "rm -rf ~/app && mkdir -p ~/app" || {
        log_error "Failed to create remote directory"
        return 1
    }
    
    log_info "Creating archive..."
    tar czf /tmp/deploy_archive.tar.gz \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.env' \
        --exclude='venv' \
        --exclude='.DS_Store' \
        . || {
        log_error "Failed to create archive"
        return 1
    }
    
    log_info "Uploading archive..."
    scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
        /tmp/deploy_archive.tar.gz "${SSH_USERNAME}@${SERVER_IP}:/tmp/" || {
        log_error "Failed to upload archive"
        rm -f /tmp/deploy_archive.tar.gz
        return 1
    }
    
    log_info "Extracting files on server..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USERNAME}@${SERVER_IP}" \
        "cd ~/app && tar xzf /tmp/deploy_archive.tar.gz && rm /tmp/deploy_archive.tar.gz" || {
        log_error "Failed to extract files"
        rm -f /tmp/deploy_archive.tar.gz
        return 1
    }
    
    # Cleanup local archive
    rm -f /tmp/deploy_archive.tar.gz
    
    log_success "Files transferred successfully"
}

# Deploy application
deploy_app() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Deploying application..."
    
    # Create deployment script
    cat > /tmp/deploy_remote.sh << EOF
#!/bin/bash
set -e

cd ~/app

echo "[INFO] Cleaning up old deployment..."
# Stop and remove old container
docker stop ${repo_name}-container 2>/dev/null || true
docker rm ${repo_name}-container 2>/dev/null || true

# Check if port is still in use and kill the process
PORT_IN_USE=\$(sudo lsof -ti:${APP_PORT} 2>/dev/null || true)
if [ -n "\$PORT_IN_USE" ]; then
    echo "[WARNING] Port ${APP_PORT} is in use by process \$PORT_IN_USE. Attempting to free it..."
    sudo kill -9 \$PORT_IN_USE 2>/dev/null || true
    sleep 2
fi

# Remove old image
docker rmi ${repo_name}:latest 2>/dev/null || true

echo "[INFO] Building Docker image..."
docker build -t ${repo_name}:latest .

echo "[INFO] Starting container on port ${APP_PORT}..."
docker run -d \
    --name ${repo_name}-container \
    -p ${APP_PORT}:80 \
    --restart unless-stopped \
    ${repo_name}:latest

echo "[SUCCESS] Container deployed successfully"
EOF

    # Create nginx config
    cat > /tmp/nginx_${repo_name}.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME} ${SERVER_IP};
    
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF

    # Transfer deployment files
    log_info "Transferring deployment configuration..."
    scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
        /tmp/deploy_remote.sh /tmp/nginx_${repo_name}.conf \
        "${SSH_USERNAME}@${SERVER_IP}:/tmp/" || {
        log_error "Failed to transfer deployment files"
        return 1
    }

    # Execute deployment
    log_info "Executing deployment on server..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USERNAME}@${SERVER_IP}" bash <<ENDSSH
        set -e
        
        cd /tmp
        chmod +x deploy_remote.sh
        bash deploy_remote.sh
        
        echo "[INFO] Configuring Nginx..."
        sudo cp nginx_${repo_name}.conf /etc/nginx/sites-available/${repo_name}
        sudo ln -sf /etc/nginx/sites-available/${repo_name} /etc/nginx/sites-enabled/
        sudo rm -f /etc/nginx/sites-enabled/default
        
        echo "[INFO] Testing Nginx configuration..."
        sudo nginx -t
        
        echo "[INFO] Reloading Nginx..."
        sudo systemctl reload nginx
        
        echo "[INFO] Cleaning up temporary files..."
        rm -f /tmp/deploy_remote.sh /tmp/nginx_${repo_name}.conf
        
        echo "[SUCCESS] Nginx configured successfully"
ENDSSH
    
    if [ $? -ne 0 ]; then
        log_error "Deployment failed"
        return 1
    fi

    # Cleanup local temp files
    rm -f /tmp/deploy_remote.sh /tmp/nginx_${repo_name}.conf
    
    log_success "Application deployed successfully"
}

# Verify deployment
verify_deployment() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Verifying deployment..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USERNAME}@${SERVER_IP}" bash <<ENDSSH
        set -e
        
        echo "[INFO] Checking Docker service..."
        if sudo systemctl is-active docker >/dev/null 2>&1; then
            echo "[SUCCESS] Docker service is running"
        else
            echo "[ERROR] Docker service is not running"
            exit 1
        fi
        
        echo "[INFO] Checking container status..."
        if docker ps | grep ${repo_name}-container >/dev/null; then
            echo "[SUCCESS] Container is running"
            docker ps | grep ${repo_name}-container
        else
            echo "[ERROR] Container is not running"
            echo "[INFO] Checking all containers..."
            docker ps -a | grep ${repo_name}-container || true
            echo "[INFO] Container logs:"
            docker logs ${repo_name}-container --tail 50 2>&1 || true
            exit 1
        fi
        
        echo "[INFO] Checking Nginx service..."
        if sudo systemctl is-active nginx >/dev/null 2>&1; then
            echo "[SUCCESS] Nginx is active"
        else
            echo "[ERROR] Nginx is not active"
            exit 1
        fi
        
        echo "[INFO] Waiting for application to be ready..."
        sleep 5
        
        echo "[INFO] Testing application endpoint..."
        if curl -f -s -m 10 http://localhost:${APP_PORT} >/dev/null 2>&1; then
            echo "[SUCCESS] Application is responding on port ${APP_PORT}"
        else
            echo "[WARNING] Direct application check failed, checking through Nginx..."
            if curl -f -s -m 10 http://localhost >/dev/null 2>&1; then
                echo "[SUCCESS] Application is accessible through Nginx"
            else
                echo "[ERROR] Application health check failed"
                echo "[INFO] Recent container logs:"
                docker logs ${repo_name}-container --tail 50
                exit 1
            fi
        fi
        
        echo "[SUCCESS] All checks passed!"
ENDSSH
    
    if [ $? -ne 0 ]; then
        log_error "Verification failed"
        return 1
    fi
    
    log_success "Deployment verification completed successfully"
}

# Main function
main() {
    log_info "========================================"
    log_info "  Starting Deployment Process"
    log_info "========================================"
    echo
    
    get_user_input
    echo
    
    setup_repo || exit 1
    echo
    
    test_connection || exit 1
    echo
    
    setup_server || exit 1
    echo
    
    transfer_files || exit 1
    echo
    
    deploy_app || exit 1
    echo
    
    verify_deployment || exit 1
    echo
    
    log_success "========================================"
    log_success "  Deployment Completed Successfully!"
    log_success "========================================"
    echo
    log_info "Access your application at:"
    log_info "  - http://${DOMAIN_NAME}"
    log_info "  - http://${SERVER_IP}"
    echo
    log_info "To check application logs:"
    log_info "  ssh -i $SSH_KEY_PATH ${SSH_USERNAME}@${SERVER_IP} 'docker logs $(basename "$GIT_REPO_URL" .git)-container'"
    echo
    log_info "To check container status:"
    log_info "  ssh -i $SSH_KEY_PATH ${SSH_USERNAME}@${SERVER_IP} 'docker ps'"
}

# Handle errors gracefully
trap 'log_error "Script failed at line $LINENO. Exit code: $?"' ERR

main "$@"

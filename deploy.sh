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
        printf "Enter application port: "
        read -r APP_PORT
        if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -gt 0 ] && [ "$APP_PORT" -lt 65536 ]; then
            break
        else
            log_error "Port must be between 1-65535"
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

    [ -f "Dockerfile" ] || { log_error "Dockerfile missing"; return 1; }
    log_success "Repository ready"
}

# Test connection
test_connection() {
    log_info "Testing connection..."
    ping -c 2 "$SERVER_IP" >/dev/null 2>&1 || log_warning "Ping failed"
    
    ssh -o ConnectTimeout=10 -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
        echo 'SSH connection successful'
    " || { log_error "SSH failed"; return 1; }
}

# Setup server
setup_server() {
    log_info "Setting up server..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
        sudo apt-get update
        sudo apt-get install -y docker.io nginx rsync
        sudo systemctl enable docker nginx
        sudo systemctl start docker nginx
        sudo usermod -aG docker \$USER
        
        # Create app directory
        mkdir -p ~/app
        
        echo 'Server setup complete'
    " || { log_error "Server setup failed"; return 1; }
}

# Transfer files to server
transfer_files() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Transferring files to server..."
    
    # Use rsync to transfer project files (excluding .git)
    rsync -avz --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        ./ "${SSH_USERNAME}@${SERVER_IP}:~/app/" || { 
        log_error "File transfer failed"; 
        return 1; 
    }
    
    log_success "Files transferred successfully"
}

# Deploy application
deploy_app() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Deploying application..."
    
    # Create deployment script
    cat > deploy_remote.sh << EOF
#!/bin/bash
set -e

cd ~/app

# Cleanup old container
docker stop ${repo_name}-container 2>/dev/null || true
docker rm ${repo_name}-container 2>/dev/null || true

# Remove old image
docker rmi ${repo_name}:latest 2>/dev/null || true

# Build and run
docker build -t ${repo_name}:latest .
docker run -d --name ${repo_name}-container -p 127.0.0.1:${APP_PORT}:${APP_PORT} ${repo_name}:latest

echo 'Container deployed'
EOF

    # Create nginx config
    cat > nginx_${repo_name}.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};
    
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
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
    scp -i "$SSH_KEY_PATH" deploy_remote.sh nginx_${repo_name}.conf "${SSH_USERNAME}@${SERVER_IP}:/tmp/" || {
        log_error "Failed to transfer deployment files"
        return 1
    }

    # Execute deployment
    ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
        cd /tmp
        chmod +x deploy_remote.sh
        bash deploy_remote.sh
        
        # Configure nginx
        sudo cp nginx_${repo_name}.conf /etc/nginx/sites-available/${repo_name}
        sudo ln -sf /etc/nginx/sites-available/${repo_name} /etc/nginx/sites-enabled/
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo nginx -t && sudo systemctl reload nginx
        
        # Cleanup
        rm -f deploy_remote.sh nginx_${repo_name}.conf
        
        echo 'Nginx configured'
    " || { log_error "Deployment failed"; return 1; }

    # Cleanup local files
    rm -f deploy_remote.sh nginx_${repo_name}.conf
    
    log_success "Application deployed"
}

# Verify deployment
verify_deployment() {
    local repo_name=$(basename "$(pwd)")
    
    log_info "Verifying deployment..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USERNAME}@${SERVER_IP}" "
        # Check container
        if docker ps | grep ${repo_name}-container; then
            echo 'Container is running'
        else
            echo 'Container not running'
            docker ps -a | grep ${repo_name}-container || true
            exit 1
        fi
        
        # Check nginx
        if sudo systemctl is-active nginx >/dev/null 2>&1; then
            echo 'Nginx is active'
        else
            echo 'Nginx not active'
            exit 1
        fi
        
        # Health check
        echo 'Waiting for application to start...'
        sleep 5
        
        if curl -f -s http://localhost:${APP_PORT} >/dev/null; then
            echo 'Application health check passed'
        else
            echo 'Application health check failed - checking logs...'
            docker logs ${repo_name}-container --tail 50
            exit 1
        fi
    " || { log_error "Verification failed"; return 1; }
}

# Main function
main() {
    log_info "Starting deployment process..."
    
    get_user_input
    setup_repo
    test_connection
    setup_server
    transfer_files  # THIS WAS MISSING!
    deploy_app
    verify_deployment
    
    log_success "Deployment completed successfully!"
    log_info "Access your application at: http://${DOMAIN_NAME}"
    log_info "Also accessible at: http://${SERVER_IP}"
}

main "$@"

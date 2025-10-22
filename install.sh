#!/bin/sh
# Simple installer for deploy.sh
# Makes the deployment script executable and provides initial setup

# Make deploy.sh executable
chmod +x deploy.sh || {
    echo "Failed to make deploy.sh executable. Please run: chmod +x deploy.sh manually"
    exit 1
}

echo "deploy.sh is now executable!"
echo "You can now run: ./deploy.sh"
echo "Run ./deploy.sh --help for usage information"
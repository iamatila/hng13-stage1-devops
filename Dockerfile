# Use official Nginx image as base
FROM nginx:alpine
# Copy our HTML file to Nginx's default directory
COPY index.html /usr/share/nginx/html/index.html
# Expose port 80 for web traffic
EXPOSE 80
# Start Nginx server
CMD ["nginx", "-g", "daemon off;"]
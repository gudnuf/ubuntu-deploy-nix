# /nix/nginx.nix
# This file generates the nginx.conf file based on the provided configuration.
{ pkgs, config }:

pkgs.writeText "nginx.conf" ''
  user ${config.nginxUser} ${config.nginxGroup};
  worker_processes auto;
  error_log /var/log/nginx/error.log;
  pid /run/nginx.pid;

  events {
      worker_connections 1024;
  }

  http {
      log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

      access_log /var/log/nginx/access.log main;

      sendfile on;
      tcp_nopush on;
      tcp_nodelay on;
      keepalive_timeout 65;
      types_hash_max_size 2048;
      server_tokens off;

      include ${pkgs.nginx}/conf/mime.types;
      default_type application/octet-stream;

      # SSL Configuration
      ssl_protocols TLSv1.2 TLSv1.3;
      ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
      ssl_prefer_server_ciphers on;
      ssl_session_cache shared:SSL:10m;
      ssl_session_timeout 10m;

      # Security headers
      add_header X-Frame-Options DENY;
      add_header X-Content-Type-Options nosniff;
      add_header X-XSS-Protection "1; mode=block";
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

      # HTTP to HTTPS redirect
      server {
          listen 80 default_server;
          listen [::]:80 default_server;
          server_name ${config.domain};
          
          # Allow Let's Encrypt challenges
          location ^~ /.well-known/acme-challenge/ {
              root /var/www/html;
              allow all;
          }
          
          # Redirect everything else to HTTPS
          location / {
              return 301 https://$server_name$request_uri;
          }
      }

      # HTTPS server
      server {
          listen 443 ssl http2 default_server;
          listen [::]:443 ssl http2 default_server;
          server_name ${config.domain};
          
          # SSL certificates
          ssl_certificate /etc/letsencrypt/live/${config.domain}/fullchain.pem;
          ssl_certificate_key /etc/letsencrypt/live/${config.domain}/privkey.pem;
          ssl_trusted_certificate /etc/letsencrypt/live/${config.domain}/chain.pem;
          
          # Enable OCSP stapling
          ssl_stapling on;
          ssl_stapling_verify on;
          resolver 8.8.8.8 8.8.4.4 valid=300s;
          resolver_timeout 5s;

          # Proxy all requests
          location / {
              proxy_pass http://${config.proxy.host}:${toString config.proxy.port};
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Port $server_port;
              
              # WebSocket support
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              
              # Timeouts
              proxy_connect_timeout 30s;
              proxy_send_timeout 30s;
              proxy_read_timeout 30s;
          }

          # Health check endpoint
          location /nginx-health {
              access_log off;
              return 200 "nginx healthy\n";
              add_header Content-Type text/plain;
          }
          
          # Security.txt
          location /.well-known/security.txt {
              return 200 "Contact: mailto:${config.email}\nExpires: 2025-12-31T23:59:59.000Z\n";
              add_header Content-Type text/plain;
          }
      }
  }
'' 
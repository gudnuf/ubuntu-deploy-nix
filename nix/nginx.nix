# /nix/nginx.nix
# This file generates the nginx.conf file based on the provided configuration.
{ pkgs, config }:

let
  # Helper function to filter regular and wildcard domains
  regularServices = builtins.filter (service: !(service.isWildcard or false)) config.services;
  wildcardServices = builtins.filter (service: service.isWildcard or false) config.services;
  
  # Helper function to generate server names for regular domains only
  regularDomains = builtins.concatStringsSep " " (map (service: service.domain) regularServices);
  
  # Helper function to generate HTTP server block for redirects
  httpRedirectBlock = ''
    # HTTP to HTTPS redirect for regular domains
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name ${regularDomains};
        
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
  '';
  
  # HTTP redirect block for wildcard subdomains
  wildcardHttpRedirectBlock = if (builtins.length wildcardServices) > 0 then ''
    # HTTP to HTTPS redirect for wildcard subdomains
    server {
        listen 80;
        listen [::]:80;
        server_name *.sando.blue;
        
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
  '' else "";
  
  # Helper function to generate HTTPS server block for a regular service
  httpsServerBlock = service: ''
    # HTTPS server for ${service.domain}
    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name ${service.domain};
        
        # SSL certificates
        ssl_certificate /etc/letsencrypt/live/${service.domain}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${service.domain}/privkey.pem;
        ssl_trusted_certificate /etc/letsencrypt/live/${service.domain}/chain.pem;
        
        # Enable OCSP stapling
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 8.8.8.8 8.8.4.4 valid=300s;
        resolver_timeout 5s;

        # Proxy all requests with CORS support for auth25.agi.cash
        location / {
            # Handle CORS preflight requests for auth25.agi.cash only
            if ($server_name = 'auth25.agi.cash') {
                set $cors_method $request_method;
            }
            if ($cors_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' '*' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
                add_header 'Access-Control-Allow-Headers' '*' always;
                add_header 'Access-Control-Max-Age' 1728000 always;
                add_header 'Content-Type' 'text/plain; charset=utf-8' always;
                add_header 'Content-Length' 0 always;
                return 204;
            }

            # Add CORS headers to responses for auth25.agi.cash only
            if ($server_name = 'auth25.agi.cash') {
                add_header 'Access-Control-Allow-Origin' '*' always;
            }

            proxy_pass http://${service.proxy.host}:${toString service.proxy.port};
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
            if ($server_name = 'auth25.agi.cash') {
                add_header 'Access-Control-Allow-Origin' '*' always;
            }
            return 200 "nginx healthy for ${service.domain}\n";
            add_header Content-Type text/plain;
        }
        
        # Security.txt
        location /.well-known/security.txt {
            if ($server_name = 'auth25.agi.cash') {
                add_header 'Access-Control-Allow-Origin' '*' always;
            }
            return 200 "Contact: mailto:${service.email}\nExpires: 2025-12-31T23:59:59.000Z\n";
            add_header Content-Type text/plain;
        }
    }
  '';
  
  # Helper function to generate HTTPS server block for wildcard service
  wildcardHttpsServerBlock = service: ''
    # HTTPS server for wildcard subdomains (${service.domain})
    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name ${service.domain};
        
        # SSL certificates (wildcard certificate)
        ssl_certificate /etc/letsencrypt/live/sando.blue/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/sando.blue/privkey.pem;
        ssl_trusted_certificate /etc/letsencrypt/live/sando.blue/chain.pem;
        
        # Enable OCSP stapling
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 8.8.8.8 8.8.4.4 valid=300s;
        resolver_timeout 5s;

        # Proxy all requests to the Rust application (handles subdomain routing internally)
        location / {
            proxy_pass http://${service.proxy.host}:${toString service.proxy.port};
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

        # Health check endpoint for wildcard subdomains
        location /nginx-health {
            access_log off;
            return 200 "nginx healthy for wildcard subdomain $server_name\n";
            add_header Content-Type text/plain;
        }
    }
  '';
  
  # Generate all HTTPS server blocks
  regularHttpsServerBlocks = builtins.concatStringsSep "\n\n" (map httpsServerBlock regularServices);
  wildcardHttpsServerBlocks = builtins.concatStringsSep "\n\n" (map wildcardHttpsServerBlock wildcardServices);

in

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
      add_header X-Frame-Options SAMEORIGIN;
      add_header X-Content-Type-Options nosniff;
      add_header X-XSS-Protection "1; mode=block";
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

      ${httpRedirectBlock}

      ${wildcardHttpRedirectBlock}

      ${regularHttpsServerBlocks}

      ${wildcardHttpsServerBlocks}
  }
'' 
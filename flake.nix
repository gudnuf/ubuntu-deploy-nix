{
  description = "Nginx server with TLS and reverse proxy support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Configuration variables - edit these for your domain
        domain = builtins.getEnv "DOMAIN";
        email = builtins.getEnv "EMAIL";
        
        # Function to generate nginx config with domain and proxy
        makeNginxConfig = domain: email: pkgs.writeText "nginx.conf" ''
          user root;
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
                  server_name ${domain};
                  
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
                  server_name ${domain};
                  
                  # SSL certificates
                  ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
                  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
                  ssl_trusted_certificate /etc/letsencrypt/live/${domain}/chain.pem;
                  
                  # Enable OCSP stapling
                  ssl_stapling on;
                  ssl_stapling_verify on;
                  resolver 8.8.8.8 8.8.4.4 valid=300s;
                  resolver_timeout 5s;

                  # Proxy all requests to localhost:8085
                  location / {
                      proxy_pass http://127.0.0.1:8085;
                      proxy_set_header Host $host;
                      proxy_set_header X-Real-IP $remote_addr;
                      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto $scheme;
                      proxy_set_header X-Forwarded-Host $host;
                      proxy_set_header X-Forwarded-Port $server_port;
                      
                      # WebSocket support (in case your service uses WebSockets)
                      proxy_http_version 1.1;
                      proxy_set_header Upgrade $http_upgrade;
                      proxy_set_header Connection "upgrade";
                      
                      # Timeouts
                      proxy_connect_timeout 30s;
                      proxy_send_timeout 30s;
                      proxy_read_timeout 30s;
                  }

                  # Health check endpoint (served directly by nginx)
                  location /nginx-health {
                      access_log off;
                      return 200 "nginx healthy\n";
                      add_header Content-Type text/plain;
                  }
                  
                  # Security.txt
                  location /.well-known/security.txt {
                      return 200 "Contact: mailto:${email}\nExpires: 2025-12-31T23:59:59.000Z\n";
                      add_header Content-Type text/plain;
                  }
              }
          }
        '';

        # Simple index.html for fallback (though it won't be used with proxy_pass)
        indexHtml = pkgs.writeText "index.html" ''
          <!DOCTYPE html>
          <html>
          <head>
              <title>🔒 Nginx Reverse Proxy</title>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
          </head>
          <body>
              <h1>🚀 Nginx Reverse Proxy Active</h1>
              <p>All requests are being forwarded to localhost:8085</p>
              <p>Domain: ${domain}</p>
          </body>
          </html>
        '';

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nginx
            certbot
            openssl
            curl
            dig
          ];
        };

        packages = {
          # Setup script with proxy support
          setup = pkgs.writeShellScriptBin "setup-nginx-proxy" ''
            set -e
            
            # Check for required environment variables
            if [ -z "$DOMAIN" ]; then
              echo "❌ DOMAIN environment variable is required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash EMAIL=you@email.com nix run .#setup"
              exit 1
            fi
            
            if [ -z "$EMAIL" ]; then
              echo "❌ EMAIL environment variable is required for Let's Encrypt"
              echo "💡 Usage: DOMAIN=mint25.agi.cash EMAIL=you@email.com nix run .#setup"
              exit 1
            fi
            
            echo "🔧 Setting up nginx reverse proxy for domain: $DOMAIN"
            echo "🎯 Will forward all requests to localhost:8085"
            
            # Create necessary directories
            sudo mkdir -p /var/www/html
            sudo mkdir -p /var/log/nginx
            sudo mkdir -p /etc/nginx
            sudo mkdir -p /run
            sudo mkdir -p /etc/letsencrypt
            
            # Create fallback index.html (won't be used with proxy)
            sudo tee /var/www/html/index.html > /dev/null << EOF
          <!DOCTYPE html>
          <html>
          <head>
              <title>🔒 Nginx Reverse Proxy</title>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
          </head>
          <body>
              <h1>🚀 Nginx Reverse Proxy Active</h1>
              <p>All requests are being forwarded to localhost:8085</p>
              <p>Domain: $DOMAIN</p>
          </body>
          </html>
          EOF
            
            # Set permissions
            sudo chmod 755 /var/www/html
            sudo chmod 644 /var/www/html/index.html
            sudo chmod 755 /var/log/nginx
            
            # Create log files
            sudo touch /var/log/nginx/access.log
            sudo touch /var/log/nginx/error.log
            sudo chmod 644 /var/log/nginx/*.log
            
            echo "✅ Basic setup complete for $DOMAIN"
            echo "🎯 Configured to proxy all requests to localhost:8085"
            echo "📋 Next steps:"
            echo "   1. Point your domain's A record to this server's IP"
            echo "   2. Make sure your service is running on localhost:8085"
            echo "   3. Run: DOMAIN=$DOMAIN EMAIL=$EMAIL nix run .#get-cert"
            echo "   4. Run: DOMAIN=$DOMAIN nix run .#start"
          '';

          # Get SSL certificate (updated to use proxy config)
          get-cert = pkgs.writeShellScriptBin "get-ssl-cert" ''
            set -e
            
            if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
              echo "❌ DOMAIN and EMAIL environment variables are required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash EMAIL=you@email.com nix run .#get-cert"
              exit 1
            fi
            
            echo "🔒 Obtaining SSL certificate for $DOMAIN"
            
            # First, start nginx with basic HTTP config for ACME challenge
            echo "🚀 Starting nginx for ACME challenge..."
            
            # Create temporary nginx config for ACME
            sudo tee /etc/nginx/nginx.conf > /dev/null << 'EOF'
          user root;
          worker_processes auto;
          error_log /var/log/nginx/error.log;
          pid /run/nginx.pid;
          events { worker_connections 1024; }
          http {
            server {
              listen 80;
              server_name _;
              root /var/www/html;
              location ^~ /.well-known/acme-challenge/ {
                allow all;
              }
              location / {
                return 200 "ACME challenge server ready\n";
                add_header Content-Type text/plain;
              }
            }
          }
          EOF
            
            # Start nginx for ACME challenge
            sudo pkill -f "nginx: master process" 2>/dev/null || true
            sleep 2
            sudo ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            
            # Wait for nginx to start
            sleep 3
            
            # Test if domain resolves to this server
            echo "🔍 Checking domain resolution..."
            DOMAIN_IP=$(dig +short $DOMAIN)
            SERVER_IP=$(curl -s http://ipv4.icanhazip.com/ || echo "unknown")
            
            echo "📍 Domain $DOMAIN resolves to: $DOMAIN_IP"
            echo "📍 This server's IP: $SERVER_IP"
            
            if [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$SERVER_IP" != "unknown" ]; then
              echo "⚠️  Warning: Domain may not point to this server"
              echo "   Make sure your DNS A record points $DOMAIN to $SERVER_IP"
              read -p "Continue anyway? (y/N): " -n 1 -r
              echo
              if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
              fi
            fi
            
            # Get certificate
            echo "📜 Requesting certificate from Let's Encrypt..."
            sudo ${pkgs.certbot}/bin/certbot certonly \
              --webroot \
              --webroot-path /var/www/html \
              --email $EMAIL \
              --agree-tos \
              --no-eff-email \
              --domains $DOMAIN
            
            # Stop temporary nginx
            sudo pkill -f "nginx: master process"
            
            echo "✅ SSL certificate obtained successfully!"
            echo "📋 Certificate files:"
            sudo ls -la /etc/letsencrypt/live/$DOMAIN/
            
            echo "🔧 Now installing reverse proxy nginx configuration..."
            
            # Generate nginx config with reverse proxy
            TEMP_CONF=$(mktemp)
            cat > $TEMP_CONF << EOF
          user root;
          worker_processes auto;
          error_log /var/log/nginx/error.log;
          pid /run/nginx.pid;

          events {
              worker_connections 1024;
          }

          http {
              log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                              '\$status \$body_bytes_sent "\$http_referer" '
                              '"\$http_user_agent" "\$http_x_forwarded_for"';

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
                  server_name $DOMAIN;
                  
                  # Allow Let's Encrypt challenges
                  location ^~ /.well-known/acme-challenge/ {
                      root /var/www/html;
                      allow all;
                  }
                  
                  # Redirect everything else to HTTPS
                  location / {
                      return 301 https://\$server_name\$request_uri;
                  }
              }

              # HTTPS server with reverse proxy
              server {
                  listen 443 ssl http2 default_server;
                  listen [::]:443 ssl http2 default_server;
                  server_name $DOMAIN;
                  
                  # SSL certificates
                  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
                  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
                  ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
                  
                  # Enable OCSP stapling
                  ssl_stapling on;
                  ssl_stapling_verify on;
                  resolver 8.8.8.8 8.8.4.4 valid=300s;
                  resolver_timeout 5s;

                  # Proxy all requests to localhost:8085
                  location / {
                      proxy_pass http://127.0.0.1:8085;
                      proxy_set_header Host \$host;
                      proxy_set_header X-Real-IP \$remote_addr;
                      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto \$scheme;
                      proxy_set_header X-Forwarded-Host \$host;
                      proxy_set_header X-Forwarded-Port \$server_port;
                      
                      # WebSocket support (in case your service uses WebSockets)
                      proxy_http_version 1.1;
                      proxy_set_header Upgrade \$http_upgrade;
                      proxy_set_header Connection "upgrade";
                      
                      # Timeouts
                      proxy_connect_timeout 30s;
                      proxy_send_timeout 30s;
                      proxy_read_timeout 30s;
                  }

                  # Health check endpoint (served directly by nginx)
                  location /nginx-health {
                      access_log off;
                      return 200 "nginx healthy\\n";
                      add_header Content-Type text/plain;
                  }
                  
                  # Security.txt
                  location /.well-known/security.txt {
                      return 200 "Contact: mailto:$EMAIL\\nExpires: 2025-12-31T23:59:59.000Z\\n";
                      add_header Content-Type text/plain;
                  }
              }
          }
          EOF
            
            sudo cp $TEMP_CONF /etc/nginx/nginx.conf
            rm $TEMP_CONF
            
            echo "✅ Setup complete! Start nginx with: DOMAIN=$DOMAIN nix run .#start"
            echo "🎯 All requests to https://$DOMAIN will be forwarded to localhost:8085"
            echo "⚠️  Make sure your service is running on localhost:8085 before starting nginx"
          '';

          # Renew certificates
          renew-cert = pkgs.writeShellScriptBin "renew-ssl-cert" ''
            echo "🔄 Renewing SSL certificates..."
            sudo ${pkgs.certbot}/bin/certbot renew --quiet
            
            if [ $? -eq 0 ]; then
              echo "✅ Certificate renewal successful"
              echo "🔄 Reloading nginx..."
              sudo pkill -HUP -f "nginx: master process" 2>/dev/null || echo "Nginx not running"
            else
              echo "❌ Certificate renewal failed"
              exit 1
            fi
          '';

          # Enhanced start script
          start = pkgs.writeShellScriptBin "start-nginx-proxy" ''
            set -e
            
            if [ -z "$DOMAIN" ]; then
              echo "❌ DOMAIN environment variable is required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash nix run .#start"
              exit 1
            fi
            
            echo "🚀 Starting nginx reverse proxy for $DOMAIN..."
            echo "🎯 Will forward all requests to localhost:8085"
            
            # Check if service is running on localhost:8085
            echo "🔍 Checking if service is running on localhost:8085..."
            if curl -s --connect-timeout 5 http://localhost:8085 > /dev/null 2>&1; then
              echo "✅ Service is responding on localhost:8085"
            else
              echo "⚠️  Warning: No service detected on localhost:8085"
              echo "   Make sure your service is running before accessing the domain"
            fi
            
            # Check if certificates exist
            if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
              echo "❌ SSL certificates not found for $DOMAIN"
              echo "📋 Run this first: DOMAIN=$DOMAIN EMAIL=your@email.com nix run .#get-cert"
              exit 1
            fi
            
            # Check nginx config
            if [ ! -f /etc/nginx/nginx.conf ]; then
              echo "❌ Nginx configuration not found"
              echo "📋 Run this first: DOMAIN=$DOMAIN EMAIL=your@email.com nix run .#setup"
              exit 1
            fi
            
            # Test configuration
            echo "🧪 Testing nginx configuration..."
            if ! sudo ${pkgs.nginx}/bin/nginx -t -c /etc/nginx/nginx.conf; then
              echo "❌ Nginx configuration test failed!"
              exit 1
            fi
            
            # Stop existing nginx
            sudo pkill -f "nginx: master process" 2>/dev/null || true
            sleep 2
            
            # Start nginx
            echo "🚀 Starting nginx reverse proxy..."
            sudo ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            
            sleep 2
            
            # Verify it started
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx reverse proxy started successfully!"
              echo "🌐 Your domain: https://$DOMAIN"
              echo "🎯 All requests will be forwarded to localhost:8085"
              echo "🩺 Nginx health check: https://$DOMAIN/nginx-health"
              echo "🔒 SSL test: https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"
              
              # Quick local tests
              echo ""
              echo "🧪 Quick tests:"
              if curl -s -f http://localhost/nginx-health > /dev/null 2>&1; then
                echo "   ✅ HTTP health check (should redirect to HTTPS)"
              fi
              
              if curl -s -f -k https://localhost/nginx-health > /dev/null 2>&1; then
                echo "   ✅ HTTPS nginx health check"
              fi
            else
              echo "❌ Nginx failed to start!"
              echo "📋 Check error logs: sudo tail /var/log/nginx/error.log"
              exit 1
            fi
          '';

          # Test proxy functionality
          test-proxy = pkgs.writeShellScriptBin "test-proxy" ''
            if [ -z "$DOMAIN" ]; then
              echo "❌ DOMAIN environment variable is required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash nix run .#test-proxy"
              exit 1
            fi
            
            echo "🧪 Testing reverse proxy functionality for $DOMAIN"
            echo "================================================="
            
            # Test localhost:8085 directly
            echo "🔍 Testing localhost:8085 directly:"
            if curl -s --connect-timeout 5 -w "Status: %{http_code}\n" http://localhost:8085 > /tmp/direct_test 2>&1; then
              echo "✅ Direct connection successful"
              echo "Response: $(head -1 /tmp/direct_test)"
            else
              echo "❌ Direct connection failed"
              cat /tmp/direct_test
            fi
            
            echo ""
            echo "🔍 Testing proxy through nginx:"
            if curl -s --connect-timeout 5 -w "Status: %{http_code}\n" -k https://localhost > /tmp/proxy_test 2>&1; then
              echo "✅ Proxy connection successful"
              echo "Response: $(head -1 /tmp/proxy_test)"
            else
              echo "❌ Proxy connection failed"
              cat /tmp/proxy_test
            fi
            
            echo ""
            echo "🔍 Testing domain access:"
            if curl -s --connect-timeout 10 -w "Status: %{http_code}\n" https://$DOMAIN > /tmp/domain_test 2>&1; then
              echo "✅ Domain connection successful"
              echo "Response: $(head -1 /tmp/domain_test)"
            else
              echo "❌ Domain connection failed"
              cat /tmp/domain_test
            fi
            
            rm -f /tmp/direct_test /tmp/proxy_test /tmp/domain_test
          '';

          # SSL status check
          ssl-status = pkgs.writeShellScriptBin "ssl-status" ''
            if [ -z "$DOMAIN" ]; then
              echo "❌ DOMAIN environment variable is required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash nix run .#ssl-status"
              exit 1
            fi
            
            echo "🔒 SSL Status for $DOMAIN"
            echo "========================="
            
            # Check certificate files
            if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
              echo "✅ Certificate directory exists"
              echo "📋 Certificate files:"
              sudo ls -la /etc/letsencrypt/live/$DOMAIN/
              
              echo ""
              echo "📅 Certificate expiry:"
              sudo ${pkgs.openssl}/bin/openssl x509 -in /etc/letsencrypt/live/$DOMAIN/cert.pem -noout -dates
              
              echo ""
              echo "🔍 Certificate details:"
              sudo ${pkgs.openssl}/bin/openssl x509 -in /etc/letsencrypt/live/$DOMAIN/cert.pem -noout -subject -issuer
            else
              echo "❌ No certificates found for $DOMAIN"
            fi
            
            echo ""
            echo "🌐 Online SSL test:"
            echo "   https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"
            
            echo ""
            echo "🧪 Quick connection test:"
            if ${pkgs.openssl}/bin/openssl s_client -connect $DOMAIN:443 -servername $DOMAIN < /dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
              echo "   ✅ SSL connection successful"
            else
              echo "   ❌ SSL connection failed"
            fi
          '';

          # Combined run script
          run = pkgs.writeShellScriptBin "run-nginx-proxy" ''
            if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
              echo "❌ DOMAIN and EMAIL environment variables are required"
              echo "💡 Usage: DOMAIN=mint25.agi.cash EMAIL=you@email.com nix run .#run"
              exit 1
            fi
            
            echo "🚀 Complete nginx reverse proxy setup for $DOMAIN..."
            ${self.packages.${system}.setup}/bin/setup-nginx-proxy
            ${self.packages.${system}.get-cert}/bin/get-ssl-cert
            ${self.packages.${system}.start}/bin/start-nginx-proxy
          '';

          # Inherit other scripts from original
          stop = pkgs.writeShellScriptBin "stop-nginx" ''
            echo "🛑 Stopping nginx..."
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "📊 Found nginx master process: $(pgrep -f 'nginx: master process')"
              sudo pkill -f "nginx: master process"
              sleep 2
              
              if pgrep -f "nginx: master process" > /dev/null; then
                echo "⚠️  Nginx still running, force killing..."
                sudo pkill -9 -f "nginx: master process"
                sleep 1
              fi
              
              if ! pgrep -f "nginx: master process" > /dev/null; then
                echo "✅ Nginx stopped successfully!"
              else
                echo "❌ Failed to stop nginx"
              fi
            else
              echo "ℹ️  No nginx processes found"
            fi
          '';

          # Enhanced status with proxy info
          status = pkgs.writeShellScriptBin "nginx-status" ''
            echo "📊 Nginx Reverse Proxy Status:"
            echo "=============================="
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx is running"
              echo "📊 Processes:"
              ps aux | grep -E "nginx: (master|worker)" | grep -v grep
              echo ""
              echo "📊 Listening ports:"
              sudo ss -tlnp | grep -E ":(80|443)" || echo "No processes listening on ports 80/443"
            else
              echo "❌ Nginx is not running"
            fi
            
            echo ""
            echo "🎯 Backend service check (localhost:8085):"
            if curl -s --connect-timeout 5 http://localhost:8085 > /dev/null 2>&1; then
              echo "   ✅ Service is responding on localhost:8085"
            else
              echo "   ❌ No service responding on localhost:8085"
            fi
            
            echo ""
            echo "🧪 Quick tests:"
            
            echo -n "HTTP (port 80): "
            if curl -s -f http://localhost/ > /dev/null 2>&1; then
              echo "✅ PASS (should redirect to HTTPS)"
            else
              echo "❌ FAIL"
            fi
            
            echo -n "HTTPS (port 443): "
            if curl -s -f -k https://localhost/ > /dev/null 2>&1; then
              echo "✅ PASS"
            else
              echo "❌ FAIL"
            fi
            
            echo -n "Nginx health endpoint: "
            if curl -s -f -k https://localhost/nginx-health > /dev/null 2>&1; then
              echo "✅ PASS"
            else
              echo "❌ FAIL"
            fi
            
            if [ ! -z "$DOMAIN" ]; then
              echo -n "Domain HTTPS: "
              if curl -s -f https://$DOMAIN/nginx-health > /dev/null 2>&1; then
                echo "✅ PASS"
              else
                echo "❌ FAIL"
              fi
            fi
          '';

          logs = pkgs.writeShellScriptBin "nginx-logs" ''
            case "$1" in
              access)
                echo "📋 Access logs:"
                sudo tail -f /var/log/nginx/access.log
                ;;
              error)
                echo "📋 Error logs:"
                sudo tail -f /var/log/nginx/error.log
                ;;
              *)
                echo "Usage: nginx-logs {access|error}"
                echo ""
                echo "Recent access logs:"
                sudo tail -10 /var/log/nginx/access.log 2>/dev/null || echo "No access logs yet"
                echo ""
                echo "Recent error logs:"
                sudo tail -10 /var/log/nginx/error.log 2>/dev/null || echo "No error logs yet"
                ;;
            esac
          '';
        };

        # Apps for easy access
        apps = {
          setup = flake-utils.lib.mkApp {
            drv = self.packages.${system}.setup;
          };
          get-cert = flake-utils.lib.mkApp {
            drv = self.packages.${system}.get-cert;
          };
          renew-cert = flake-utils.lib.mkApp {
            drv = self.packages.${system}.renew-cert;
          };
          start = flake-utils.lib.mkApp {
            drv = self.packages.${system}.start;
          };
          stop = flake-utils.lib.mkApp {
            drv = self.packages.${system}.stop;
          };
          status = flake-utils.lib.mkApp {
            drv = self.packages.${system}.status;
          };
          ssl-status = flake-utils.lib.mkApp {
            drv = self.packages.${system}.ssl-status;
          };
          test-proxy = flake-utils.lib.mkApp {
            drv = self.packages.${system}.test-proxy;
          };
          logs = flake-utils.lib.mkApp {
            drv = self.packages.${system}.logs;
          };
          run = flake-utils.lib.mkApp {
            drv = self.packages.${system}.run;
          };
        };
      }
    );
}

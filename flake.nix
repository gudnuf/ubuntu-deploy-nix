{
  description = "A modular Nginx reverse proxy flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Import modular configuration
        config = import ./nix/config.nix;
        nginx-generator = import ./nix/nginx.nix;

        # Generate nginx config from the modular files
        nginx-config = nginx-generator { pkgs = pkgs; config = config; };

        # Helper functions for multi-service support
        allDomains = map (service: service.domain) config.services;
        allDomainsStr = builtins.concatStringsSep ", " allDomains;
        
        # Generate service info for display
        serviceInfo = service: "  - ${service.domain} -> ${service.proxy.host}:${toString service.proxy.port}";
        allServicesInfo = builtins.concatStringsSep "\n" (map serviceInfo config.services);

        # Temporary nginx config for the ACME challenge
        acme-nginx-config = pkgs.writeText "nginx-acme.conf" ''
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
        '';

        # Enhanced index.html showing all services
        indexHtml = pkgs.writeText "index.html" ''
          <!DOCTYPE html>
          <html>
          <head>
              <title>🔒 Nginx Reverse Proxy</title>
              <meta charset="utf-8">
              <style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .service { margin: 20px 0; padding: 15px; border-left: 4px solid #007acc; background: #f5f5f5; }
                .domain { font-weight: bold; color: #007acc; }
                .proxy { color: #666; }
              </style>
          </head>
          <body>
              <h1>🚀 Nginx Reverse Proxy Active</h1>
              <p>Currently proxying ${toString (builtins.length config.services)} service(s):</p>
              ${builtins.concatStringsSep "\n" (map (service: ''
                <div class="service">
                  <div class="domain">${service.domain}</div>
                  <div class="proxy">Proxying to: ${service.proxy.host}:${toString service.proxy.port}</div>
                  <div class="proxy">Contact: ${service.email}</div>
                </div>
              '') config.services)}
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
          shellHook = ''
            echo "🚀 Nginx reverse proxy dev environment"
            echo "📋 Configured services:"
            ${builtins.concatStringsSep "\n" (map (service: ''echo "  - ${service.domain} -> ${service.proxy.host}:${toString service.proxy.port}"'') config.services)}
            echo ""
            echo "Available commands: nix run .#<command>"
            echo "Commands: setup, get-cert, start, stop, status, logs, etc."
          '';
        };

        packages = {
          # Main nginx config, built from our modular files
          nginx-config = nginx-config;

          # Script to regenerate and install the nginx config
          regenerate-config = pkgs.writeShellScriptBin "regenerate-config" ''
            set -e
            echo "🔄 Regenerating nginx configuration for ${toString (builtins.length config.services)} service(s)"
            echo "📋 Domains: ${allDomainsStr}"

            echo "🧪 Testing new configuration from Nix store..."
            if ! sudo ${pkgs.nginx}/bin/nginx -t -c ${nginx-config}; then
              echo "❌ New configuration is invalid! Aborting."
              exit 1
            fi

            echo "✅ New configuration is valid. Installing..."
            sudo cp ${nginx-config} /etc/nginx/nginx.conf

            echo "🚀 Configuration regenerated. Reload nginx to apply changes:"
            echo "   sudo pkill -HUP -f 'nginx: master process'"
          '';
          
          # Initial setup script
          setup = pkgs.writeShellScriptBin "setup-nginx" ''
            set -e
            echo "🔧 Setting up nginx for ${toString (builtins.length config.services)} service(s)"
            echo "📋 Domains: ${allDomainsStr}"
            
            # Create nginx user and group if they don't exist
            if ! getent group ${config.nginxGroup} >/dev/null; then
                echo "👥 Creating group '${config.nginxGroup}'..."
                sudo groupadd -r ${config.nginxGroup}
            fi
            if ! id -u ${config.nginxUser} >/dev/null 2>&1; then
                echo "👤 Creating user '${config.nginxUser}'..."
                sudo useradd -r -g ${config.nginxGroup} -s /bin/false -d /var/www/html ${config.nginxUser}
            fi
            
            # Create necessary directories
            sudo mkdir -p /var/www/html /var/log/nginx /etc/nginx /run /etc/letsencrypt
            
            # Create fallback index.html
            sudo cp ${indexHtml} /var/www/html/index.html
            
            # Set permissions
            sudo chown -R ${config.nginxUser}:${config.nginxGroup} /var/log/nginx
            sudo chmod 755 /var/www/html
            sudo chmod 644 /var/www/html/index.html
            
            # Create log files and set permissions
            sudo touch /var/log/nginx/access.log /var/log/nginx/error.log
            sudo chmod 640 /var/log/nginx/*.log
            
            echo "✅ Basic setup complete."
            echo "📋 Next steps:"
            echo "   1. Point your domains' A records to this server's IP:"
            ${builtins.concatStringsSep "\n" (map (service: ''echo "      - ${service.domain}"'') config.services)}
            echo "   2. Run 'nix run .#get-cert' to obtain SSL certificates."
            echo "   3. Run 'nix run .#start' to start the reverse proxy."
          '';

          # Get SSL certificates for all domains
          get-cert = pkgs.writeShellScriptBin "get-ssl-cert" ''
            set -e
            echo "🔒 Obtaining SSL certificates for ${toString (builtins.length config.services)} domain(s)"
            echo "📋 Domains: ${allDomainsStr}"
            
            echo "🚀 Starting nginx for ACME challenge..."
            sudo cp ${acme-nginx-config} /etc/nginx/nginx.conf
            sudo pkill -f "nginx: master process" 2>/dev/null || true
            sleep 2
            sudo ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            sleep 3
            
            echo "🔍 Checking domain resolution..."
            SERVER_IP=$(${pkgs.curl}/bin/curl -s http://ipv4.icanhazip.com/ || echo "unknown")
            echo "📍 This server's IP: $SERVER_IP"
            
            # Check each domain
            ${builtins.concatStringsSep "\n" (map (service: ''
              DOMAIN_IP=$(${pkgs.dig}/bin/dig +short ${service.domain})
              echo "📍 Domain ${service.domain} resolves to: $DOMAIN_IP"
              if [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$SERVER_IP" != "unknown" ]; then
                echo "⚠️  Warning: ${service.domain} may not point to this server"
              fi
            '') config.services)}
            
            read -p "Continue with certificate requests? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
              sudo pkill -f "nginx: master process"
              exit 1
            fi
            
            # Request certificates for each domain
            ${builtins.concatStringsSep "\n" (map (service: ''
              echo "📜 Requesting certificate for ${service.domain}..."
              sudo ${pkgs.certbot}/bin/certbot certonly \
                --webroot \
                --webroot-path /var/www/html \
                --email ${service.email} \
                --agree-tos \
                --no-eff-email \
                --domains ${service.domain}
            '') config.services)}
            
            sudo pkill -f "nginx: master process"
            
            echo "✅ SSL certificates obtained successfully!"
            
            echo "🔧 Installing reverse proxy nginx configuration..."
            sudo cp ${nginx-config} /etc/nginx/nginx.conf
            
            echo "✅ Setup complete! Start nginx with: nix run .#start"
          '';

          # Renew certificates
          renew-cert = pkgs.writeShellScriptBin "renew-ssl-cert" ''
            echo "🔄 Renewing SSL certificates for all domains..."
            if sudo ${pkgs.certbot}/bin/certbot renew --quiet; then
              echo "✅ Certificate renewal successful"
              echo "🔄 Reloading nginx..."
              sudo pkill -HUP -f "nginx: master process" 2>/dev/null || echo "Nginx not running"
            else
              echo "❌ Certificate renewal failed"
              exit 1
            fi
          '';

          # Start nginx with checks for all backend services
          start = pkgs.writeShellScriptBin "start-nginx" ''
            set -e
            echo "🚀 Starting nginx reverse proxy for ${toString (builtins.length config.services)} service(s)"
            echo "📋 Domains: ${allDomainsStr}"
            
            echo "🔍 Checking backend services..."
            ${builtins.concatStringsSep "\n" (map (service: ''
              echo "  Checking ${service.domain} -> ${service.proxy.host}:${toString service.proxy.port}..."
              if ${pkgs.curl}/bin/curl -s --connect-timeout 5 http://${service.proxy.host}:${toString service.proxy.port} > /dev/null 2>&1; then
                echo "    ✅ Service is responding"
              else
                echo "    ⚠️  Warning: No service detected on ${service.proxy.host}:${toString service.proxy.port}"
              fi
            '') config.services)}
            
            # Check if all certificates exist
            MISSING_CERTS=""
            ${builtins.concatStringsSep "\n" (map (service: ''
              if ! sudo test -f "/etc/letsencrypt/live/${service.domain}/fullchain.pem"; then
                MISSING_CERTS="$MISSING_CERTS ${service.domain}"
              fi
            '') config.services)}
            
            if [ -n "$MISSING_CERTS" ]; then
              echo "❌ SSL certificates not found for:$MISSING_CERTS"
              echo "📋 Run 'nix run .#get-cert' first"
              exit 1
            fi
            
            echo "🧪 Testing nginx configuration..."
            if ! sudo ${pkgs.nginx}/bin/nginx -t -c /etc/nginx/nginx.conf; then
              echo "❌ Nginx configuration test failed!"
              exit 1
            fi
            
            sudo pkill -f "nginx: master process" 2>/dev/null || true
            sleep 2
            
            echo "🚀 Starting nginx reverse proxy..."
            sudo ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            sleep 2
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx reverse proxy started successfully!"
              echo "🌐 Your domains:"
              ${builtins.concatStringsSep "\n" (map (service: ''echo "   https://${service.domain}"'') config.services)}
            else
              echo "❌ Nginx failed to start! Check logs: nix run .#logs -- error"
              exit 1
            fi
          '';

          # Stop nginx
          stop = pkgs.writeShellScriptBin "stop-nginx" ''
            echo "🛑 Stopping nginx..."
            if pgrep -f "nginx: master process" > /dev/null; then
              sudo pkill -f "nginx: master process"
              sleep 1
              if ! pgrep -f "nginx: master process" > /dev/null; then
                echo "✅ Nginx stopped successfully!"
              else
                echo "❌ Failed to stop nginx"
                sudo pkill -9 -f "nginx: master process"
              fi
            else
              echo "ℹ️  No nginx processes found"
            fi
          '';

          # Enhanced status check for all services
          status = pkgs.writeShellScriptBin "nginx-status" ''
            echo "📊 Nginx Reverse Proxy Status"
            echo "=============================="
            echo "Services: ${toString (builtins.length config.services)}"
            echo "Domains: ${allDomainsStr}"
            echo ""
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx is running"
              sudo ss -tlnp | grep -E ":(80|443)" || echo "Not listening on 80/443"
            else
              echo "❌ Nginx is not running"
            fi
            
            echo ""
            echo "🎯 Backend service checks:"
            ${builtins.concatStringsSep "\n" (map (service: ''
              echo "  ${service.domain} -> ${service.proxy.host}:${toString service.proxy.port}:"
              if ${pkgs.curl}/bin/curl -s --connect-timeout 2 http://${service.proxy.host}:${toString service.proxy.port} > /dev/null 2>&1; then
                echo "    ✅ Service is responding"
              else
                echo "    ❌ No service responding"
              fi
            '') config.services)}
            
            echo ""
            echo "🔒 SSL Certificate status:"
            ${builtins.concatStringsSep "\n" (map (service: ''
              if [ -f "/etc/letsencrypt/live/${service.domain}/fullchain.pem" ]; then
                EXPIRY=$(sudo openssl x509 -enddate -noout -in /etc/letsencrypt/live/${service.domain}/fullchain.pem | cut -d= -f2)
                echo "  ${service.domain}: ✅ Valid (expires: $EXPIRY)"
              else
                echo "  ${service.domain}: ❌ Certificate not found"
              fi
            '') config.services)}
          '';

          # View logs
          logs = pkgs.writeShellScriptBin "nginx-logs" ''
            case "$1" in
              access) sudo tail -f /var/log/nginx/access.log;;
              error) sudo tail -f /var/log/nginx/error.log;;
              *)
                echo "Usage: nix run .#logs -- {access|error}"
                echo -e "\nRecent access logs:"
                sudo tail -10 /var/log/nginx/access.log 2>/dev/null || echo "  (empty)"
                echo -e "\nRecent error logs:"
                sudo tail -10 /var/log/nginx/error.log 2>/dev/null || echo "  (empty)"
                ;;
            esac
          '';
        };

        # Apps for easy access
        apps = {
          default = flake-utils.lib.mkApp { drv = self.packages.${system}.status; };
          setup = flake-utils.lib.mkApp { drv = self.packages.${system}.setup; };
          get-cert = flake-utils.lib.mkApp { drv = self.packages.${system}.get-cert; };
          renew-cert = flake-utils.lib.mkApp { drv = self.packages.${system}.renew-cert; };
          start = flake-utils.lib.mkApp { drv = self.packages.${system}.start; };
          stop = flake-utils.lib.mkApp { drv = self.packages.${system}.stop; };
          status = flake-utils.lib.mkApp { drv = self.packages.${system}.status; };
          logs = flake-utils.lib.mkApp { drv = self.packages.${system}.logs; };
          regenerate-config = flake-utils.lib.mkApp { drv = self.packages.${system}.regenerate-config; };
        };
      }
    );
}

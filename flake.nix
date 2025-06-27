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

        # Basic index.html
        indexHtml = pkgs.writeText "index.html" ''
          <!DOCTYPE html>
          <html>
          <head>
              <title>🔒 Nginx Reverse Proxy</title>
              <meta charset="utf-8">
          </head>
          <body>
              <h1>🚀 Nginx Reverse Proxy Active</h1>
              <p>Proxying to: ${config.proxy.host}:${toString config.proxy.port}</p>
              <p>Domain: ${config.domain}</p>
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
            echo "Nginx reverse proxy dev environment"
            echo "Domain: ${config.domain}"
            echo "Proxy: ${config.proxy.host}:${toString config.proxy.port}"
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
            echo "🔄 Regenerating nginx configuration for ${config.domain}"

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
            echo "🔧 Setting up nginx for domain: ${config.domain}"
            
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
            echo "   1. Point your domain's A record to this server's IP."
            echo "   2. Run 'nix run .#get-cert' to obtain SSL certificates."
            echo "   3. Run 'nix run .#start' to start the reverse proxy."
          '';

          # Get SSL certificate
          get-cert = pkgs.writeShellScriptBin "get-ssl-cert" ''
            set -e
            echo "🔒 Obtaining SSL certificate for ${config.domain}"
            
            echo "🚀 Starting nginx for ACME challenge..."
            sudo cp ${acme-nginx-config} /etc/nginx/nginx.conf
            sudo pkill -f "nginx: master process" 2>/dev/null || true
            sleep 2
            sudo ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            sleep 3
            
            echo "🔍 Checking domain resolution..."
            DOMAIN_IP=$(${pkgs.dig}/bin/dig +short ${config.domain})
            SERVER_IP=$(${pkgs.curl}/bin/curl -s http://ipv4.icanhazip.com/ || echo "unknown")
            
            echo "📍 Domain ${config.domain} resolves to: $DOMAIN_IP"
            echo "📍 This server's IP: $SERVER_IP"
            
            if [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$SERVER_IP" != "unknown" ]; then
              echo "⚠️  Warning: Domain may not point to this server"
              read -p "Continue anyway? (y/N): " -n 1 -r
              echo
              if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
              fi
            fi
            
            echo "📜 Requesting certificate from Let's Encrypt..."
            sudo ${pkgs.certbot}/bin/certbot certonly \
              --webroot \
              --webroot-path /var/www/html \
              --email ${config.email} \
              --agree-tos \
              --no-eff-email \
              --domains ${config.domain}
            
            sudo pkill -f "nginx: master process"
            
            echo "✅ SSL certificate obtained successfully!"
            
            echo "🔧 Installing reverse proxy nginx configuration..."
            sudo cp ${nginx-config} /etc/nginx/nginx.conf
            
            echo "✅ Setup complete! Start nginx with: nix run .#start"
          '';

          # Renew certificates
          renew-cert = pkgs.writeShellScriptBin "renew-ssl-cert" ''
            echo "🔄 Renewing SSL certificates..."
            if sudo ${pkgs.certbot}/bin/certbot renew --quiet; then
              echo "✅ Certificate renewal successful"
              echo "🔄 Reloading nginx..."
              sudo pkill -HUP -f "nginx: master process" 2>/dev/null || echo "Nginx not running"
            else
              echo "❌ Certificate renewal failed"
              exit 1
            fi
          '';

          # Start nginx
          start = pkgs.writeShellScriptBin "start-nginx" ''
            set -e
            echo "🚀 Starting nginx reverse proxy for ${config.domain}"
            
            echo "🔍 Checking if service is running on ${config.proxy.host}:${toString config.proxy.port}..."
            if ${pkgs.curl}/bin/curl -s --connect-timeout 5 http://${config.proxy.host}:${toString config.proxy.port} > /dev/null 2>&1; then
              echo "✅ Service is responding"
            else
              echo "⚠️  Warning: No service detected on ${config.proxy.host}:${toString config.proxy.port}"
            fi
            
            if [ ! -f "/etc/letsencrypt/live/${config.domain}/fullchain.pem" ]; then
              echo "❌ SSL certificates not found for ${config.domain}"
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
              echo "🌐 Your domain: https://${config.domain}"
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

          # Nginx status
          status = pkgs.writeShellScriptBin "nginx-status" ''
            echo "📊 Nginx Reverse Proxy Status for ${config.domain}"
            echo "=================================="
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx is running"
              sudo ss -tlnp | grep -E ":(80|443)" || echo "Not listening on 80/443"
            else
              echo "❌ Nginx is not running"
            fi
            
            echo ""
            echo "🎯 Backend service check (${config.proxy.host}:${toString config.proxy.port}):"
            if ${pkgs.curl}/bin/curl -s --connect-timeout 2 http://${config.proxy.host}:${toString config.proxy.port} > /dev/null 2>&1; then
              echo "   ✅ Service is responding"
            else
              echo "   ❌ No service responding"
            fi
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
        apps = flake-utils.lib.mkApp { drv = self.packages.${system}.setup; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.get-cert; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.renew-cert; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.start; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.stop; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.status; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.logs; } //
               flake-utils.lib.mkApp { drv = self.packages.${system}.regenerate-config; };
      }
    );
}

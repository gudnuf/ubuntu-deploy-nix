{
  description = "Simple nginx server setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Basic nginx configuration
        nginxConfig = pkgs.writeText "nginx.conf" ''
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

              include ${pkgs.nginx}/conf/mime.types;
              default_type application/octet-stream;

              # Default server block
              server {
                  listen 80 default_server;
                  listen [::]:80 default_server;
                  server_name _;
                  root /var/www/html;
                  index index.html index.htm;

                  location / {
                      try_files $uri $uri/ =404;
                  }

                  # Basic health check endpoint
                  location /health {
                      access_log off;
                      return 200 "healthy\n";
                      add_header Content-Type text/plain;
                  }
              }
          }
        '';

        # Simple index.html
        indexHtml = pkgs.writeText "index.html" ''
          <!DOCTYPE html>
          <html>
          <head>
              <title>Nginx is running!</title>
              <style>
                  body { font-family: Arial, sans-serif; margin: 40px; }
                  .container { max-width: 600px; margin: 0 auto; text-align: center; }
                  .status { color: #28a745; font-size: 24px; }
              </style>
          </head>
          <body>
              <div class="container">
                  <h1>🚀 Nginx is running!</h1>
                  <p class="status">✅ Server is operational</p>
                  <p>This page is served by nginx configured with Nix flakes.</p>
                  <hr>
                  <p><small>Timestamp: $(date)</small></p>
              </div>
          </body>
          </html>
        '';

      in
      {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nginx
            curl
          ];
        };

        # Packages
        packages = {
          # Setup script
          setup = pkgs.writeShellScriptBin "setup-nginx" ''
            set -e
            
            echo "🔧 Setting up nginx..."
            
            # Create necessary directories with proper permissions
            sudo mkdir -p /var/www/html
            sudo mkdir -p /var/log/nginx
            sudo mkdir -p /etc/nginx
            sudo mkdir -p /run
            
            # Copy configuration
            sudo cp ${nginxConfig} /etc/nginx/nginx.conf
            sudo cp ${indexHtml} /var/www/html/index.html
            
            # Update timestamp in index.html
            sudo sed -i "s/\$(date)/$(date)/" /var/www/html/index.html
            
            # Set proper permissions
            sudo chmod 755 /var/www/html
            sudo chmod 644 /var/www/html/index.html
            sudo chmod 755 /var/log/nginx
            sudo chmod 644 /etc/nginx/nginx.conf
            
            # Create log files if they don't exist
            sudo touch /var/log/nginx/access.log
            sudo touch /var/log/nginx/error.log
            sudo chmod 644 /var/log/nginx/*.log
            
            echo "✅ Nginx configuration ready!"
            echo "📁 Config: /etc/nginx/nginx.conf"
            echo "📁 Web root: /var/www/html"
            echo "📁 Logs: /var/log/nginx/"
          '';

          # Start nginx
          start = pkgs.writeShellScriptBin "start-nginx" ''
            set -e
            
            echo "🚀 Starting nginx..."
            
            # Check if setup was run first
            if [ ! -f /etc/nginx/nginx.conf ]; then
              echo "⚠️  Configuration not found. Running setup first..."
              ${self.packages.${system}.setup}/bin/setup-nginx
            fi
            
            # Show the nginx path we're using
            echo "📍 Using nginx from: ${pkgs.nginx}/bin/nginx"
            
            # Test configuration first
            echo "🧪 Testing configuration..."
            if ! ${pkgs.nginx}/bin/nginx -t -c /etc/nginx/nginx.conf; then
              echo "❌ Nginx configuration test failed!"
              exit 1
            fi
            
            # Stop any existing nginx processes (be more specific)
            echo "🛑 Stopping any existing nginx processes..."
            if pgrep -f "nginx: master process" > /dev/null; then
              pkill -f "nginx: master process" && echo "   Stopped existing nginx master" || true
              sleep 2
            else
              echo "   No existing nginx processes found"
            fi
            
            # Check that port 80 is free
            if ss -tln | grep :80 > /dev/null; then
              echo "⚠️  Port 80 is already in use:"
              ss -tlnp | grep :80
              echo "You may need to stop the service using port 80 first"
            fi
            
            # Start nginx
            echo "🚀 Starting nginx daemon..."
            ${pkgs.nginx}/bin/nginx -c /etc/nginx/nginx.conf
            
            # Give it a moment to start
            sleep 2
            
            # Check if it started successfully
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx started successfully!"
              echo "📊 Master process PID: $(pgrep -f 'nginx: master process')"
              echo "📊 Worker processes: $(pgrep -f 'nginx: worker process' | wc -l)"
              
              # Verify it's listening
              if ss -tln | grep :80 > /dev/null; then
                echo "🌐 Nginx is listening on port 80"
                echo "🧪 Test it: curl http://localhost/"
                echo "🩺 Health check: curl http://localhost/health"
              else
                echo "⚠️  Nginx started but not listening on port 80"
              fi
            else
              echo "❌ Nginx failed to start!"
              echo "📋 Checking error logs..."
              tail -10 /var/log/nginx/error.log 2>/dev/null || echo "No error logs found"
              exit 1
            fi
          '';

          # Stop nginx
          stop = pkgs.writeShellScriptBin "stop-nginx" ''
            echo "🛑 Stopping nginx..."
            
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "📊 Found nginx master process: $(pgrep -f 'nginx: master process')"
              pkill -f "nginx: master process"
              sleep 2
              
              # Check if it's really stopped
              if pgrep -f "nginx: master process" > /dev/null; then
                echo "⚠️  Nginx still running, force killing..."
                pkill -9 -f "nginx: master process"
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

          # Status check
          status = pkgs.writeShellScriptBin "nginx-status" ''
            echo "📊 Nginx Status:"
            echo "==============="
            
            # Check for nginx processes more specifically
            if pgrep -f "nginx: master process" > /dev/null; then
              echo "✅ Nginx is running"
              echo "📊 Processes:"
              ps aux | grep -E "nginx: (master|worker)" | grep -v grep
              echo ""
              echo "📊 Listening ports:"
              sudo ss -tlnp | grep :80 || echo "No processes listening on port 80"
            else
              echo "❌ Nginx is not running"
              echo "📊 Checking for any nginx processes:"
              ps aux | grep nginx | grep -v grep || echo "No nginx processes found"
            fi
            
            echo ""
            echo "🧪 Quick tests:"
            
            # Test health endpoint
            echo -n "Health check: "
            if curl -s -f http://localhost/health > /dev/null 2>&1; then
              echo "✅ PASS"
            else
              echo "❌ FAIL"
            fi
            
            # Test main page
            echo -n "Main page: "
            if curl -s -f http://localhost/ > /dev/null 2>&1; then
              echo "✅ PASS"
            else
              echo "❌ FAIL"
            fi
            
            # Show what's actually on port 80
            echo ""
            echo "🔍 Port 80 details:"
            sudo lsof -i :80 2>/dev/null || echo "Nothing listening on port 80"
          '';

          # Test script
          test = pkgs.writeShellScriptBin "test-nginx" ''
            echo "🧪 Testing nginx setup..."
            echo "========================"
            
            echo "1. Testing main page:"
            if curl -s http://localhost/ | grep -q "Nginx is running"; then
              echo "   ✅ Main page OK"
            else
              echo "   ❌ Main page failed"
            fi
            
            echo "2. Testing health endpoint:"
            if curl -s http://localhost/health | grep -q "healthy"; then
              echo "   ✅ Health endpoint OK"
            else
              echo "   ❌ Health endpoint failed"
            fi
            
            echo "3. Testing 404 handling:"
            if curl -s -o /dev/null -w "%{http_code}" http://localhost/nonexistent | grep -q "404"; then
              echo "   ✅ 404 handling OK"
            else
              echo "   ❌ 404 handling failed"
            fi
            
            echo ""
            echo "🌐 If all tests pass, nginx is working correctly!"
          '';

          # Logs viewer
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

          # Combined setup and start
          run = pkgs.writeShellScriptBin "run-nginx" ''
            set -e
            echo "🚀 Setting up and starting nginx..."
            ${self.packages.${system}.setup}/bin/setup-nginx
            ${self.packages.${system}.start}/bin/start-nginx
          '';

          # Debug helper
          debug = pkgs.writeShellScriptBin "debug-nginx" ''
            echo "🔍 Nginx Debug Information"
            echo "=========================="
            
            echo "1. Configuration file:"
            if [ -f /etc/nginx/nginx.conf ]; then
              echo "   ✅ /etc/nginx/nginx.conf exists"
              echo "   📝 Testing config:"
              sudo ${pkgs.nginx}/bin/nginx -t -c /etc/nginx/nginx.conf
            else
              echo "   ❌ /etc/nginx/nginx.conf missing"
            fi
            
            echo ""
            echo "2. Process information:"
            echo "   All nginx processes:"
            ps aux | grep nginx | grep -v grep || echo "   No nginx processes"
            
            echo ""
            echo "3. Network information:"
            echo "   Processes on port 80:"
            sudo lsof -i :80 || echo "   Nothing on port 80"
            echo "   All listening ports:"
            sudo ss -tlnp | head -10
            
            echo ""
            echo "4. File permissions:"
            ls -la /etc/nginx/nginx.conf 2>/dev/null || echo "   Config file missing"
            ls -la /var/www/html/ 2>/dev/null || echo "   Web root missing"
            
            echo ""
            echo "5. Recent error logs:"
            sudo tail -5 /var/log/nginx/error.log 2>/dev/null || echo "   No error logs"
            
            echo ""
            echo "6. Manual curl tests:"
            echo "   Testing localhost:80..."
            curl -v http://localhost/ 2>&1 | head -10 || echo "   Connection failed"
          '';
        };

        # Apps for easy access
        apps = {
          setup = flake-utils.lib.mkApp {
            drv = self.packages.${system}.setup;
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
          test = flake-utils.lib.mkApp {
            drv = self.packages.${system}.test;
          };
          logs = flake-utils.lib.mkApp {
            drv = self.packages.${system}.logs;
          };
          run = flake-utils.lib.mkApp {
            drv = self.packages.${system}.run;
          };
          debug = flake-utils.lib.mkApp {
            drv = self.packages.${system}.debug;
          };
        };
      }
    );
}

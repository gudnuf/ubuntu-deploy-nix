# /nix/config.nix
# This file contains the configuration for your nginx reverse proxy.
# Edit the values below to match your setup.
{
  # List of services to proxy
  services = [
    {
      # The main domain
      domain = "sando.blue";
      
      # The email address for Let's Encrypt notifications for this domain.
      email = "johntoshi21@proton.me";
      
      # The backend service to proxy requests to.
      proxy = {
        host = "127.0.0.1";
        port = 3000;
      };
    }
    {
      # Wildcard subdomain for holesail connections
      domain = "*.sando.blue";
      isWildcard = true;
      
      # The email address for Let's Encrypt notifications for this domain.
      email = "johntoshi21@proton.me";
      
      # The backend service to proxy requests to (your Rust app handles subdomain routing)
      proxy = {
        host = "127.0.0.1";
        port = 3000;
      };
    }
  ];

  # The user and group for nginx worker processes.
  # This user will be created during the setup process if it doesn't exist.
  nginxUser = "gudnuf";
  nginxGroup = "gudnuf";
} 
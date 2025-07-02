# /nix/config.nix
# This file contains the configuration for your nginx reverse proxy.
# Edit the values below to match your setup.
{
  # List of services to proxy
  services = [
    {
      # The domain you want to serve.
      domain = "example.com";
      
      # The email address for Let's Encrypt notifications for this domain.
      email = "you@example.com";
      
      # The backend service to proxy requests to.
      proxy = {
        host = "127.0.0.1";
        port = 8085;
      };
    }
    
    # Example: Add more services as needed
    {
      domain = "api.example.com";
      email = "admin@example.com";
      proxy = {
        host = "127.0.0.1";
        port = 3000;
      };
    }
  ];

  # The user and group for nginx worker processes.
  # This user will be created during the setup process if it doesn't exist.
  nginxUser = "nginx";
  nginxGroup = "nginx";
} 
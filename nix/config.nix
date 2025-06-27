# /nix/config.nix
# This file contains the configuration for your nginx reverse proxy.
# Edit the values below to match your setup.
{
  # The domain you want to serve.
  domain = "example.com";

  # The email address for Let's Encrypt notifications.
  email = "you@example.com";

  # The backend service to proxy requests to.
  proxy = {
    host = "127.0.0.1";
    port = 8085;
  };

  # The user and group for nginx worker processes.
  # This user will be created during the setup process if it doesn't exist.
  nginxUser = "nginx";
  nginxGroup = "nginx";
} 
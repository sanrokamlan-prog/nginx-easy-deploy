# Security Policy

## Sensitive data

Migration archives can contain TLS private keys, ACME account data and HTTP basic-auth files. Use `export --encrypt`, keep archives mode `0600`, and transfer them through a trusted channel. Do not attach real migration archives, certificates or keys to public issues.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Include the affected command, operating system, Nginx version and a minimal reproduction that contains no real credentials or private keys.

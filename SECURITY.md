# Security

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it through the
[AWS vulnerability reporting process](https://aws.amazon.com/security/vulnerability-reporting/)
and include the repository name, affected version, reproduction steps, and impact.

## Intended use

This repository is sample code for demonstration and educational purposes. It is not
production-ready. Before using it with real source code or credentials, perform a
threat-model review, test the controls in your own AWS environment, and adapt the IAM,
network, data-retention, monitoring, and incident-response configuration.

The agents process merge request content written by third parties. Titles, descriptions,
diffs, commit messages, source files, and comments are untrusted input. Server-side input
validation is the security boundary; prompt instructions are defense in depth. For
production, attach Amazon Bedrock Guardrails with prompt-attack and sensitive-information
filters and require human approval for high-impact actions. The GitLab MCP rejects
oversized comments, raw HTML, images, GitLab quick actions (such as `/merge` or
`/approve`), control characters, link reference definitions, and links to hosts other
than the configured GitLab host before retrieving a credential or posting.

## Credential handling

The GitLab personal access token is read from AWS Secrets Manager only by the GitLab MCP
runtime. Clone authentication is passed to Git through an ephemeral HTTP header; it must
never be embedded in a repository URL or stored in `.git/config`.

If an earlier release was deployed, rotate its GitLab token and remove every historical
version of `repositories/*/.git/config` from the primary and replica workspace buckets.
Treat such a token as exposed because the bucket is versioned and cross-Region replicated.

## Accepted security debt and production recommendations

The following limitations are accepted for this sample and must be reconsidered for
production:

1. `ecr:GetAuthorizationToken` uses `Resource = "*"` because the action has no
   resource-level permission. Keep it in a separate statement and monitor it in
   CloudTrail.
2. AWS X-Ray write and sampling actions and `cloudwatch:PutMetricData` require wildcard
   resources. The metrics permission is restricted to the `bedrock-agentcore` namespace;
   monitor telemetry changes.
3. Global Bedrock inference profiles require foundation-model resources in multiple
   Regions. The sample restricts them to the configured profile in this account and the
   Claude Sonnet 4.5 model family. Review model access and cost controls.
4. The sample KMS key policies retain the standard account-root administration statement.
   Production deployments should grant administration to a dedicated deployment role and
   keep decrypt permission limited to the GitLab MCP role through AWS Secrets Manager.
5. VPC flow-log retention is configurable. Use at least 365 days where investigation and
   compliance requirements call for it.
6. Runtime egress allows HTTPS and DNS to the internet so the GitLab host and AWS APIs are
   reachable through NAT. Production deployments should add VPC endpoints and restrict
   non-AWS egress to approved GitLab destinations with an egress-control service such as
   AWS Network Firewall.
7. Runtime code returns sanitized operational errors, but additional exception-specific
   handling and alerting may be appropriate for production.
8. The development configuration permits immediate secret deletion and short KMS deletion
    windows. Production environments should use 30-day recovery windows, disable forced
    bucket deletion, and consider `prevent_destroy`.

## Release hygiene

Before external publication:

- Confirm that all code and assets are original or cleared for publication.
- Publish from a clean or squashed history that contains no customer names, credentials,
  internal endpoints, generated scan reports, or IDE configuration.
- Run automated security scans and review every suppression.
- Rotate test credentials and remove retained credential-bearing object versions.

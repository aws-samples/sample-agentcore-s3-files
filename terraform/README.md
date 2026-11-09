# Terraform — AgentCore + S3 Files shared storage

This directory provisions the infrastructure for the pattern: a VPC, an S3 Files
filesystem (shared persistent storage), and an Amazon Bedrock AgentCore runtime that
mounts it. Module settings come from `environments/<env>/config.yaml`; region and naming
come from the matching `terraform.tfvars`.

## Layout

```
terraform/
├── main.tf                     # Root: loads config.yaml + wires modules together
├── variables.tf                # Root input variables (project_name, environment, region)
├── outputs.tf                  # Root outputs (VPC, buckets, filesystem, access points, runtimes)
├── providers.tf                # Terraform + provider version constraints
├── environments/
│   ├── terraform.tfvars.example  # template — copy into an env folder
│   └── dev/
│       ├── config.yaml         # per-environment module config (VPC, agents, s3files, ...)
│       └── terraform.tfvars    # region + naming for dev (account = AWS_PROFILE)
└── modules/
    ├── vpc/                    # VPC + public/private subnets + IGW + NAT
    ├── ecr/                    # ECR repos (derived from agentcore config) — Phase 1
    ├── secrets/                # KMS-encrypted GitLab token secret
    ├── s3files/                # S3 bucket + IAM role + S3 Files fs/mount/access points
    ├── mcp/                    # Runtime SG, scoped roles, and MCP runtimes
    ├── gateway/                # AWS_IAM-authenticated MCP gateway and targets
    └── agentcore/              # Analyzer and reviewer A2A runtimes
```

Every module follows the standard three-file layout — `main.tf` (locals + resources),
`variables.tf` (inputs), `outputs.tf` (outputs). Variables and outputs are never inlined
into `main.tf`.

## Configuration (`config.yaml`)

`main.tf` reads the file with `yamldecode(file(...))` and passes each top-level block to
the matching module. The three blocks:

### `vpc`
```yaml
vpc:
  create_vpc: true              # true = build a new VPC; false = use an existing one
  id: ""                        # existing VPC id      (used only when create_vpc: false)
  private_subnet_ids: []        # existing subnet ids  (used only when create_vpc: false)
  cidr_block: "10.0.0.0/16"     # new-VPC settings     (used only when create_vpc: true)
  availability_zone_count: 2
  availability_zone_names:      # fixed AZ allowlist; length >= availability_zone_count
    - "ap-southeast-1a"
    - "ap-southeast-1b"
  enable_nat_gateway: true
  flow_log_retention_days: 365
```
The root module resolves this into `effective_vpc_id` / `effective_private_subnet_ids` —
module outputs when `create_vpc: true`, config values when `false` — so the rest of the
stack is agnostic to which path you chose.

### `s3files`
```yaml
s3files:
  workspace_prefix: "agentcore/workspaces/"
  retention_days: 30
  mount_path: "/mnt"
```
S3 Files (bucket + IAM role + filesystem + mount targets + dedicated access points) is
created in a single apply. Workspace objects use customer-managed KMS keys in both Regions;
the access-log buckets remain on SSE-S3 because S3 server access-log delivery does not
support SSE-KMS. The access point ARNs are apply-time values Terraform resolves within the
same apply (via the `null_resource` → `data.external` chain).

### `agentcore`
```yaml
agentcore:
  create_runtimes: false        # phase gate (ECR images must exist first) — see "Two-phase deploy" below
  image_tag: "latest"           # tag appended to each derived ECR image
  mcp_servers:                  # mount S3 Files, protocol=MCP
    workspace: { description: "..." }   # container_uri optional — defaults to ECR
    gitlab:    { description: "..." }
  agents:                       # A2A, no mount — reach storage via the MCP servers
    analyzer:  { description: "..." }   # calls the reviewer via A2A
    reviewer:  { description: "..." }   # ranks + posts the GitLab comment
  idle_runtime_session_timeout: 900
  max_lifetime: 28800
```
The module creates one `aws_bedrockagentcore_agent_runtime` per entry with `for_each`:
each MCP server mounts its dedicated access point (`server_protocol = "MCP"`); agents run
without a mount (`server_protocol = "A2A"`). MCP runtime IDs are injected into the agents
as env vars.

**A2A handoff (no orchestrator):** the analyzer invokes the reviewer directly. The reviewer
runtime is created first and its id is injected into the analyzer as `REVIEWER_RUNTIME_ID`
(the two agents are separate resources, not a `for_each` map, because a self-reference inside
`for_each` would be a dependency cycle). Kick off the workflow with
`scripts/start_review.py`, which invokes only the analyzer. Outputs: `mcp_runtime_arns`,
`analyzer_runtime_arn`, `analyzer_runtime_id`, `reviewer_runtime_arn`.

## Is a VPC required?

**Yes — a VPC with private subnets is mandatory.** S3 Files exposes the bucket over
**NFS (TCP 2049)** through **mount targets that live inside VPC subnets**; there is no
VPC-less or public path to an S3 Files mount. Concretely:

- Mount targets get a VPC-private ENI per subnet — that's what the NFS client connects to.
- The `agentcore` security group allows inbound/outbound TCP 2049 (self-referencing) so
  the runtime ENIs and mount-target ENIs can talk.
- The AgentCore runtime uses **VPC networking mode** on the same subnets + SG.

You don't have to *pre-create* a VPC: leave `create_vpc: true` and the `vpc` module builds
one. If you already have a VPC, set `create_vpc: false` and supply `id` +
`private_subnet_ids`.

## Choosing account & region

Two different mechanisms — don't conflate them:

| What | Set by | How |
| --- | --- | --- |
| **AWS account** | your **credentials** at runtime | `export AWS_PROFILE=my-account` (or env keys / SSO). Terraform deploys into whatever `aws sts get-caller-identity` resolves — there is no account ID in any file. |
| **Region + naming** | a **var-file** | `project_name`, `environment`, `aws_region` in `environments/<env>/terraform.tfvars`. |

Per-environment var-files (`environments/<env>/terraform.tfvars`) keep `plan`/`apply`/
`destroy` consistent (no inline `-var=` to forget). They hold region + naming only — no
secrets — so the committed dev file is a safe default; copy `environments/terraform.tfvars.example`
for a new environment.

```bash
# edit environments/dev/terraform.tfvars (region / project_name)
export AWS_PROFILE=my-dev-account       # picks the ACCOUNT
terraform plan -var-file=environments/dev/terraform.tfvars -out=tfplan
terraform apply tfplan
```

> `environment` also selects `environments/<env>/config.yaml`. For a new env (e.g. prod),
> copy `environments/dev/` (config.yaml + terraform.tfvars) to `environments/prod/` and
> adjust, then run with `-var-file=environments/prod/terraform.tfvars`.

## Two-phase deploy (why `create_runtimes` exists)

The deploy is two phases because the AgentCore runtimes reference container images that must
be **built and pushed before the runtimes are created**. On a first-ever
apply those images don't exist yet, so runtime creation is gated on a plan-time flag
(`agentcore.create_runtimes`): Phase 1 stands up everything the images need (VPC, ECR, S3
Files, bucket, IAM); you push the images; Phase 2 creates the runtimes.

> **S3 Files is created in a single apply** — the `s3files` module manages the filesystem,
> mount targets, and dedicated access points (through the AWS CLI, since S3 Files has no
> native Terraform resource yet). Terraform resolves the apply-time access point ARNs via
> `data.external` and feeds them to the runtimes as normal value dependencies.

```bash
terraform init -upgrade
VF="-var-file=environments/dev/terraform.tfvars"

# ── Phase 1: VPC + security group + ECR repos + S3 Files (bucket/fs/access points) + IAM ──
#   config.yaml → agentcore.create_runtimes: false
terraform plan  $VF -out=tfplan && terraform apply tfplan

#   Build & push the images to the Phase-1 ECR repos:
./scripts/build_and_push.sh          # (from repo root)

# ── Phase 2: the AgentCore runtimes (MCP servers + agents) ──
#   flip config.yaml → agentcore.create_runtimes: true
terraform plan  $VF -out=tfplan && terraform apply tfplan
```

A single `create_runtimes` flag drives Phase 2 — flip it once. Within that apply Terraform
orders things correctly by **value dependency**: the MCP runtimes reference the access
point ARNs (so they wait for them), and the agents reference the MCP runtime IDs (so they
wait for those). The runtimes' `for_each`/`count` keys gate on the plan-time `create_runtimes`
flag — **never** on the apply-time ARN — so `plan` always succeeds.

> **Why the flag at all?** The container images don't exist until `build_and_push.sh` runs,
> and Terraform `for_each`/`count` keys must be known at *plan* time. The plan-time
> `create_runtimes` flag lets Phase 1 stand up the ECR repos (and everything else) without
> the runtimes; you push images; Phase 2 turns the flag on. `depends_on` can't replace this
> — it orders apply steps but doesn't make a not-yet-pushed image plan-time-known.

ECR repositories are created in **Phase 1** so images exist to push before Phase 2
references them. Their names are **derived automatically** from the `agentcore` config —
one `<agent>-agent` repo per agent and one `<server>-mcp` repo per MCP server. Push targets
are exposed via the root output `ecr_repository_urls`. Always `plan -out=tfplan` then
`apply tfplan` so you apply exactly the plan you reviewed.

## Provider versions

Pinned in `providers.tf`; the `aws_bedrockagentcore_agent_runtime` resource requires the AWS provider 6.x line.

| Requirement | Constraint |
| --- | --- |
| Terraform core | `>= 1.10` |
| `hashicorp/aws` | `~> 6.50` |
| `hashicorp/external` | `~> 2.3` |
| `hashicorp/null` | `~> 3.2` |

> The `aws_bedrockagentcore_agent_runtime` resource only exists in the **AWS provider 6.x**
> line — do not downgrade below `~> 6.50`. Run `terraform init -upgrade` after changing
> constraints.

## Common commands

```bash
terraform fmt -recursive                          # format
terraform validate                                # validate config
terraform plan  -var-file=environments/dev/terraform.tfvars -out=tfplan  # preview -> saved plan file
terraform show  tfplan                            # review the saved plan
terraform apply tfplan                            # apply exactly that plan
terraform destroy -var-file=environments/dev/terraform.tfvars          # tear down (see note below)
```

> **Teardown note:** because the S3 Files filesystem/mount targets/access points are created
> via CLI, `terraform destroy` removes the bucket, IAM role, SG, and VPC but not the S3
> Files objects. Delete those with `aws s3files delete-access-point / delete-mount-target /
> delete-file-system` before (or after) destroy.

## Troubleshooting

### `InvalidSignatureException` / `InvalidHttpRequest: Unable to parse request` (intermittent)

If `plan`/`apply` fails on **some** resources with a mix of:

```
api error InvalidSignatureException: The request signature we calculated does not match ...
api error InvalidHttpRequest: The HTTP request is invalid. Reason: Unable to parse request
```

…while the **AWS CLI works fine** (`aws sts get-caller-identity`, `aws ec2 describe-vpcs`, etc.),
this is almost always **concurrent-request corruption**, not credentials, clock, or the config.
Terraform fires ~10 parallel API requests by default; a VPN or TLS-inspection agent (Zscaler,
Netskope, corporate proxy) can intermittently mangle a fraction of those concurrent HTTPS
streams, so *some* requests fail signature validation or become unparseable while most succeed.

**Fix — serialize requests with `-parallelism=1`:**

```bash
terraform plan  -parallelism=1 -var-file=environments/dev/terraform.tfvars -out=tfplan
terraform apply -parallelism=1 tfplan
```

Or set it for the whole shell session so you don't have to remember the flag:

```bash
export TF_CLI_ARGS_plan="-parallelism=1"
export TF_CLI_ARGS_apply="-parallelism=1"
export TF_CLI_ARGS_destroy="-parallelism=1"
```

Diagnostic ladder (rule things out fast — the CLI succeeding but Terraform failing is the tell):

1. `date -u` — clock within ~5 min of real UTC? (skew fails **every** request, not some.)
2. `aws sts get-caller-identity` — creds valid, right account? (works ⇒ not a creds problem.)
3. `env | grep -iE 'proxy|aws_endpoint|aws_ca_bundle'` — any interception configured?
4. `aws ec2 describe-vpcs --region <region>` — a direct write-ish call. Works ⇒ it's Terraform
   concurrency, so use `-parallelism=1`. Fails too ⇒ fix the network/VPN/creds first.

> Trade-off: `-parallelism=1` is slower (one resource at a time) but reliable on networks with
> TLS inspection. If serializing still fails, disconnect the VPN / inspection agent (or allowlist
> the AWS API endpoints) and retry.

## Conventions

- **No hardcoded values** — every tunable is a `config.yaml` key with a sensible default in
  the module's `variables.tf`.
- **No `--platform` pinned in `FROM`** — container platform is chosen at build time via
  `docker build --platform ...` (see `src/*/Dockerfile`).
- **Separate `variables.tf` / `outputs.tf` / `main.tf`** in every module.


## AgentCore runtime resource schema

The `agentcore` module uses the **`aws_bedrockagentcore_agent_runtime`** resource (note the
`_agent_` segment in the type name). Its block shapes are cross-checked against the `AWS::BedrockAgentCore::Runtime` CloudFormation /
`create-agent-runtime` API schema:

- `network_configuration { network_mode = "VPC", network_mode_config { subnets, security_groups } }`
  — the subnets/SG are **nested** under `network_mode_config`, not flat.
- `filesystem_configuration { s3_files_access_point { access_point_arn, mount_path } }`
  — Workspace mounts only `/workspaces`; GitLab mounts only `/repositories`.
- `role_arn` is **required** — agents use an agent-only role, while the Workspace and
  GitLab MCP servers use separate roles. Only MCP roles can mount S3 Files, and only the
  GitLab MCP role can read the token secret.
- `protocol_configuration { server_protocol = "MCP" }`.
- `lifecycle_configuration { idle_runtime_session_timeout, max_lifetime }` — session
  reclaim/hard-cap timeouts (seconds), wired from `config.yaml`.

### Private MCP access (not a public URL)

Agents reach the MCP server over a **private** path — **VPC Lattice** (an AgentCore
gateway target / `managedVpcResource`) or a **PrivateLink** interface endpoint
(`com.amazonaws.<region>.bedrock-agentcore`). Do **not** expose the MCP runtime through a
public URL or CloudFront: MCP uses stateful SSE / streamable HTTP that a CDN can time out,
and a public origin defeats keeping the server private. Wire this path separately from this
module.

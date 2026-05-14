# Security Implementation Summary

> **Date**: 2026-05-14  
> **Branch**: v3-secure  
> **Primary Region**: us-east-1 (COMPLETE)  
> **DR Region**: us-east-2 (PENDING)

---

## Security Controls Deployed

### 1. VPC Network Isolation

| Item | Details |
|------|---------|
| VPC CIDR | 10.0.0.0/16 (us-east-1), 10.1.0.0/16 (us-east-2 planned) |
| Private Subnets | 2 subnets in AgentCore-supported AZs |
| Public Subnets | 2 subnets (NAT Gateway placement only) |
| NAT Gateway | 1 per region (Azure AD OAuth outbound) |
| Internet Gateway | Attached to public subnets only |

### 2. VPC Endpoints (11 — all traffic stays private)

| # | Endpoint | Type | Purpose | Cost |
|---|----------|------|---------|------|
| 1 | `com.amazonaws.{region}.s3` | Gateway | Lambda code, OpenAPI schema | Free |
| 2 | `com.amazonaws.{region}.dynamodb` | Gateway | Orders + OAuth token tables | Free |
| 3 | `com.amazonaws.{region}.secretsmanager` | Interface | Gateway credentials | ~$7/mo |
| 4 | `com.amazonaws.{region}.bedrock-runtime` | Interface | LLM inference (Claude) | ~$7/mo |
| 5 | `com.amazonaws.{region}.logs` | Interface | CloudWatch observability | ~$7/mo |
| 6 | `com.amazonaws.{region}.ecr.dkr` | Interface | Runtime container images | ~$7/mo |
| 7 | `com.amazonaws.{region}.ecr.api` | Interface | Runtime image management | ~$7/mo |
| 8 | `com.amazonaws.{region}.execute-api` | Interface | Private API Gateway access | ~$7/mo |
| 9 | `com.amazonaws.{region}.bedrock-agent-runtime` | Interface | AgentCore Runtime operations | ~$7/mo |
| 10 | `com.amazonaws.{region}.bedrock-agentcore.gateway` | Interface | **MCP tool calls to Gateway** | ~$7/mo |
| 11 | `com.amazonaws.{region}.bedrock-agentcore` | Interface | **Control plane (InvokeRuntime)** | ~$7/mo |

### 3. Compute Security

| Component | VPC Attached | Security Group |
|-----------|-------------|----------------|
| dev-agent-proxy Lambda | ✅ | Lambda SG |
| dev-oauth-callback Lambda | ✅ | Lambda SG |
| dev-get-orders Lambda | ✅ | Lambda SG |
| dev-create-order Lambda | ✅ | Lambda SG |
| dev-update-order Lambda | ✅ | Lambda SG |
| dev-orders-authorizer Lambda | ✅ | Lambda SG |
| AgentCore Runtime | ✅ VPC mode | Lambda SG |

### 4. Security Groups

| SG | Inbound | Outbound |
|----|---------|----------|
| Lambda SG | None | TCP 443 → Endpoint SG; TCP 443 → 0.0.0.0/0 (via NAT for Azure AD + AgentCore control) |
| Endpoint SG | TCP 443 from Lambda SG | Default stateful return |

### 5. API Security

| API | Type | Auth | WAF | CORS |
|-----|------|------|-----|------|
| Agent Proxy (HTTP API) | Public | **JWT Authorizer** (Azure AD) | — | CloudFront domain only |
| Orders API (REST API) | REGIONAL | Custom TOKEN Authorizer (JWT) | ✅ IP rep + SQLi + rate limit | — |

### 6. IAM Hardening

| Role | Status | Notes |
|------|--------|-------|
| GatewayRole | AdministratorAccess | **Required** — AWS-managed service needs broad perms |
| RuntimeRole | Least-privilege | Scoped to Bedrock, Logs, S3, SecretsManager, Memory |
| OAuthCallbackLambdaRole | Scoped | token-vault + workload-identity-directory + specific secrets |
| AgentProxyLambdaRole | Scoped | InvokeAgentRuntime on specific ARN only |
| LambdaExecutionRole | Scoped | DynamoDB table + ec2:*NetworkInterface |
| AuthorizerExecutionRole | Scoped | CloudWatch Logs + ec2:*NetworkInterface |

---

## CloudFormation Sync Status

| Template | Live State | Sync Status |
|----------|-----------|-------------|
| `vpc-stack.yaml` | dev-vpc-v3redwood (standalone) | ✅ All 11 endpoints, correct AZs |
| `agentcore-app-stack.yaml` | AgentCoreAppStack (nested) | ✅ JWT auth, VPC mode, IAM, CORS |
| `backend-api-stack.yaml` | BackendAPIStack (nested) | ✅ Lambda VPC, WAF, ENI perms |
| `parent-regional.yaml` | secure-agentcore-app-dev-v3redwood | ✅ Passes VPC params to children |
| `frontend-stack.yaml` | WAF defined but not deployed to global stack yet | ⚠️ WAF on CloudFront pending |
| `deploy-stack-multi-region.sh` | Runtime uses VPC mode | ✅ Updated |
| `deploy-security-fast.sh` | Fast deploy helper | ✅ Working |

---

## Key Learnings (Critical for DR Deployment)

### 1. AgentCore Runtime AZ Requirements
- **us-east-1**: Supported AZ IDs are `use1-az1`, `use1-az2`, `use1-az4`
- **us-east-2**: Supported AZ IDs are `use2-az1`, `use2-az2`, `use2-az3`
- Use explicit AZ names in Mappings, NOT `!Select [index, !GetAZs]` (index-based selection can land in unsupported AZs)

### 2. Required VPC Endpoints for AgentCore VPC Mode
All 11 endpoints listed above are required. The three AgentCore-specific ones were NOT in the original design and were discovered through trial and error:
- `bedrock-agentcore.gateway` — without this, MCP tools return empty
- `bedrock-agentcore` — without this, InvokeAgentRuntime fails from Lambda in VPC
- `bedrock-agent-runtime` — for Runtime internal operations

### 3. GatewayRole Cannot Be Restricted
The AgentCore Gateway (AWS-managed service) requires `AdministratorAccess` on its IAM role. Attempts to use least-privilege caused "No MCP tools returned from Gateway" errors. AWS does not document the minimum required permissions.

### 4. Orders API Must Stay REGIONAL
The AgentCore Gateway is AWS-managed and runs OUTSIDE your VPC. It needs to call the Orders API over the public internet. Making it PRIVATE broke the Gateway→API communication. Security is enforced by JWT authorizer + WAF instead.

### 5. NetworkConfiguration Schema for AgentCore Runtime
```yaml
# CORRECT CloudFormation syntax:
NetworkConfiguration:
  NetworkMode: VPC          # Values: PUBLIC | VPC (NOT "PRIVATE")
  NetworkModeConfig:
    Subnets:                # Direct under NetworkModeConfig (NOT under VpcConfig)
      - subnet-xxx
    SecurityGroups:
      - sg-xxx
```

### 6. OAuthCallbackLambdaRole Needs Broad AgentCore Access
The `CompleteResourceTokenAuth` API operates on `workload-identity-directory` resources AND needs `secretsmanager:GetSecretValue` for `bedrock-agentcore-identity*` secrets. Scoping only to `token-vault` breaks OAuth.

### 7. Lambda SG Egress Must Allow 0.0.0.0/0
Restricting egress to just the Endpoint SG + NAT subnet CIDR is insufficient. The Lambda needs to reach the AgentCore control plane endpoint which resolves to IPs that go through the NAT Gateway. Use `0.0.0.0/0` for HTTPS egress.

### 8. VPC Stack Should Be Standalone (Not Nested)
Deploying VPC as a nested stack causes long rollback delays when failures occur. A standalone VPC stack allows independent updates and avoids cascading rollback issues.

---

## DR Region Deployment Checklist

To deploy VPC security in us-east-2:

1. [ ] Create standalone VPC stack: `dev-vpc-v3redwood` in us-east-2 (uses 10.1.0.0/16 from Mappings, AZs: us-east-2a, us-east-2b)
2. [ ] Verify AZ IDs are supported: `use2-az1`, `use2-az2`, `use2-az3` (all supported)
3. [ ] Upload templates to DR bucket: `dev-cfn-templates-v3redwood-us-east-2`
4. [ ] Update DR stack with VPC params: `secure-agentcore-app-dev-v3redwood-dr`
5. [ ] Update DR runtime to VPC mode with DR subnets/SG
6. [ ] Verify: Lambda VPC attachment, Runtime VPC mode, JWT authorizer, WAF
7. [ ] Test end-to-end via DR API endpoint

---

## Traffic Flow (After Security)

```
User Browser
    │ HTTPS
    ▼
CloudFront (WAF pending) → S3 (private, OAC)
    │ /api/* via Lambda@Edge
    ▼
HTTP API GW [JWT Authorizer] ← unauthenticated = 401
    │
    ▼ (inside VPC)
Agent Proxy Lambda [Lambda SG, private subnet]
    │ via bedrock-agentcore VPC endpoint
    ▼
AgentCore Runtime [VPC mode, private subnet]
    │ via bedrock-agentcore.gateway VPC endpoint
    ▼
AgentCore Gateway [AWS-managed, external]
    │ HTTPS (JWT + Cedar policy)
    ▼
Orders REST API GW [REGIONAL, JWT authorizer, WAF]
    │
    ▼ (inside VPC)
Orders Lambdas [Lambda SG, private subnet]
    │ via DynamoDB Gateway endpoint
    ▼
DynamoDB [private, no public access]
```

**Only 2 paths touch the public internet:**
1. AgentCore Gateway → Orders API (protected by JWT + WAF)
2. OAuth Callback Lambda → Azure AD (via NAT, required for 3-legged auth)

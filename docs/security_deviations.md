# Security Deviations — VPC & Private Networking

> **Status**: Pending implementation (post-deployment and testing)  
> **Branch**: v3-secure  
> **Date**: 2026-05-13

---

## Current State: All Traffic is Public

| Component | Current State | Risk Level |
|-----------|--------------|------------|
| AgentCore Runtime | `NetworkMode: PUBLIC` | HIGH — Agent accessible from public internet |
| Lambda Functions (7) | No VPC attachment | HIGH — All AWS SDK calls traverse public internet |
| REST API Gateway (Orders) | `REGIONAL` endpoint, public | HIGH — Accessible from anywhere |
| HTTP API Gateway (Agent Proxy) | Public, **no authorizer** | CRITICAL — Anyone can invoke the agent |
| DynamoDB access | Public endpoint | MEDIUM — No VPC endpoint |
| Secrets Manager access | Public endpoint | MEDIUM — No VPC endpoint |
| Bedrock access | Public endpoint | MEDIUM — No VPC endpoint |
| GatewayRole IAM | `AdministratorAccess` | CRITICAL — Massively over-privileged |
| CORS | `AllowOrigin: '*'` | MEDIUM — Overly permissive |
| OAuthCallbackLambdaRole | `Resource: '*'` on multiple actions | HIGH — Overly broad |

---

## Recommended Enhancements

### 1. Create a VPC with Private Subnets

- Deploy a VPC with private subnets (no internet gateway) across 2+ AZs
- Add NAT Gateway only if external calls (Azure AD OAuth) are required
- All internal AWS service communication should stay within the VPC

**Files to modify**: New `vpc-stack.yaml` template, `parent-regional.yaml`

---

### 2. VPC Endpoints (PrivateLink) for AWS Services

| Service | Endpoint Type | Cost |
|---------|--------------|------|
| DynamoDB | Gateway | Free |
| S3 | Gateway | Free |
| Secrets Manager | Interface | ~$7.20/month per AZ |
| Bedrock | Interface | ~$7.20/month per AZ |
| CloudWatch Logs | Interface | ~$7.20/month per AZ |
| Bedrock AgentCore | Interface (if available) | TBD |

**Files to modify**: New `vpc-stack.yaml` template

---

### 3. Attach Lambda Functions to VPC

- Place all 7 Lambda functions in private subnets
- Configure security groups allowing only necessary egress
- Ensures DynamoDB, Secrets Manager, and Bedrock calls stay private

**Files to modify**: `backend-api-stack.yaml`, `agentcore-app-stack.yaml`  
**Properties to add**: `VpcConfig` with `SubnetIds` and `SecurityGroupIds`

---

### 4. Switch AgentCore Runtime to PRIVATE NetworkMode

- Change `NetworkConfiguration: NetworkMode: PUBLIC` → `PRIVATE`
- Route all agent traffic through VPC

**File to modify**: `agentcore-app-stack.yaml` (AgentCoreRuntime resource)

---

### 5. Make API Gateway Private

- Convert REST API Gateway (Orders) to **Private** endpoint type
- Add VPC endpoint for `execute-api`
- Use resource policies to restrict access to the VPC only
- Add a Lambda authorizer to the Agent Proxy HTTP API (currently has NONE)

**Files to modify**: `backend-api-stack.yaml`, `agentcore-app-stack.yaml`

---

### 6. Add WAF (Web Application Firewall)

- Attach AWS WAF to CloudFront distribution
- Attach AWS WAF to API Gateway
- Rules: rate limiting, IP reputation lists, SQL injection protection, bot control

**Files to modify**: `frontend-stack.yaml`, `backend-api-stack.yaml`, or new `waf-stack.yaml`

---

### 7. Fix IAM Over-Privileges

| Role | Current | Fix |
|------|---------|-----|
| GatewayRole | `AdministratorAccess` | Replace with least-privilege: `execute-api:Invoke`, `logs:*`, specific Bedrock actions |
| OAuthCallbackLambdaRole | `bedrock-agentcore:*` on `Resource: '*'` | Scope to specific ARNs |
| OAuthCallbackLambdaRole | `secretsmanager:GetSecretValue` on `Resource: '*'` | Scope to specific secret ARNs |

**File to modify**: `agentcore-app-stack.yaml`

---

### 8. Restrict CORS

- Change `AllowOrigin: '*'` to the specific CloudFront domain
- Update both the HTTP API Gateway CORS config and the Lambda response headers

**Files to modify**: `agentcore-app-stack.yaml`, `agent_proxy.py`

---

### 9. Add Security Groups

| Security Group | Inbound | Outbound |
|----------------|---------|----------|
| Lambda SG | None | VPC endpoints, NAT Gateway (443) |
| VPC Endpoint SG | From Lambda SG (443) | None |

**Files to modify**: New `vpc-stack.yaml` template

---

## Implementation Priority

| Priority | Item | Effort |
|----------|------|--------|
| P0 (Critical) | Add authorizer to Agent Proxy HTTP API | Low |
| P0 (Critical) | Remove `AdministratorAccess` from GatewayRole | Low |
| P1 (High) | Create VPC + private subnets + VPC endpoints | Medium |
| P1 (High) | Attach Lambdas to VPC | Medium |
| P1 (High) | Switch AgentCore Runtime to PRIVATE mode | Low |
| P2 (Medium) | Add WAF to CloudFront and API Gateway | Medium |
| P2 (Medium) | Make Orders API Gateway private | Medium |
| P2 (Medium) | Scope IAM wildcards on OAuthCallbackLambdaRole | Low |
| P3 (Low) | Restrict CORS origins | Low |

---

## Architecture After Enhancements

```
User Browser ──HTTPS──► CloudFront (WAF) ──► S3 (private, OAC)
                              │
                              ▼
                    HTTP API Gateway (authorizer + WAF)
                              │
                              ▼ (VPC)
                    ┌─────────────────────────────────┐
                    │         Private Subnets          │
                    │                                  │
                    │  Agent Proxy Lambda              │
                    │       │                          │
                    │       ▼ (VPC Endpoint)           │
                    │  AgentCore Runtime (PRIVATE)     │
                    │       │                          │
                    │       ▼ (VPC Endpoint)           │
                    │  AgentCore Gateway               │
                    │       │                          │
                    │       ▼ (Private API GW)         │
                    │  Orders API Lambdas              │
                    │       │                          │
                    │       ▼ (Gateway VPC Endpoint)   │
                    │  DynamoDB                        │
                    │                                  │
                    │  VPC Endpoints:                  │
                    │  - DynamoDB (Gateway)            │
                    │  - S3 (Gateway)                  │
                    │  - Secrets Manager (Interface)   │
                    │  - Bedrock (Interface)           │
                    │  - CloudWatch Logs (Interface)   │
                    └─────────────────────────────────┘
                              │
                              ▼ (NAT Gateway — only for Azure AD)
                    login.microsoftonline.com
```

---

## Notes

- Azure AD OAuth token endpoint (`login.microsoftonline.com`) requires internet access via NAT Gateway
- VPC endpoints add ~$7.20/month per interface endpoint per AZ
- Gateway VPC endpoints (DynamoDB, S3) are free
- Lambda cold starts may increase slightly when attached to VPC (mitigated by provisioned concurrency if needed)

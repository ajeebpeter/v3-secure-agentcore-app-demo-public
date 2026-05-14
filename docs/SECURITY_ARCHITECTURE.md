# Security Architecture — Secure Agentic App (Project Redwood)

> Multi-region deployment with VPC isolation, JWT auth, WAF, and ARC failover

---

## Architecture Diagram

```mermaid
flowchart TB
    subgraph Internet["🌐 Internet"]
        User["👤 User Browser<br/>(MSAL + Azure AD JWT)"]
        AzureAD["🔐 Azure Entra ID<br/>(OAuth2 / JWKS)"]
    end

    subgraph AWS["☁️ AWS Account (823159980483)"]
        subgraph Edge["Edge Layer"]
            WAF_CF["🛡️ WAF<br/>IP Rep + SQLi + Rate Limit"]
            CF["📡 CloudFront<br/>HTTPS + OAC"]
            S3["📦 S3 Frontend<br/>Private (OAC only)"]
            LambdaEdge["⚡ Lambda@Edge<br/>ARC Origin Router"]
        end

        subgraph Primary["🟢 us-east-1 (Primary)"]
            subgraph VPC1["VPC 10.0.0.0/16"]
                subgraph Private1["Private Subnets (use1-az4, use1-az1)"]
                    APIGW1["🔒 HTTP API GW<br/>JWT Authorizer"]
                    AgentProxy1["λ Agent Proxy"]
                    Runtime1["🤖 AgentCore Runtime<br/>VPC Mode"]
                    OAuthCB1["λ OAuth Callback"]
                    OrdersLambdas1["λ Orders (GET/POST/PUT)<br/>+ JWT Authorizer λ"]
                end
                subgraph Endpoints1["VPC Endpoints (11)"]
                    EP1["DynamoDB • S3 • SecretsManager<br/>Bedrock Runtime • CloudWatch Logs<br/>ECR dkr • ECR api • execute-api<br/>bedrock-agentcore • agentcore.gateway<br/>bedrock-agent-runtime"]
                end
                NAT1["🌐 NAT Gateway<br/>(Azure AD only)"]
            end
            OrdersAPI1["🛡️ Orders REST API GW<br/>REGIONAL + JWT + WAF<br/>(AWS-managed, outside VPC)"]
            Gateway1["🔗 AgentCore Gateway<br/>(AWS-managed, outside VPC)<br/>MCP + Cedar Policy"]
        end

        subgraph DR["🟡 us-east-2 (DR)"]
            subgraph VPC2["VPC 10.1.0.0/16"]
                subgraph Private2["Private Subnets (use2-az1, use2-az2)"]
                    APIGW2["🔒 HTTP API GW<br/>JWT Authorizer"]
                    Runtime2["🤖 AgentCore Runtime<br/>VPC Mode"]
                    OrdersLambdas2["λ Orders + Agent Lambdas"]
                end
                Endpoints2["VPC Endpoints (11)"]
                NAT2["🌐 NAT Gateway"]
            end
            OrdersAPI2["🛡️ Orders REST API<br/>REGIONAL + JWT + WAF"]
            Gateway2["🔗 AgentCore Gateway<br/>(AWS-managed)"]
        end

        ARC["🔄 ARC<br/>Route53 Recovery Controller<br/>Routing Control: On/Off"]
        DDB["📊 DynamoDB Global Table<br/>(replicated us-east-1 ↔ us-east-2)"]
    end

    User -->|HTTPS| WAF_CF
    WAF_CF --> CF
    CF --> S3
    CF -->|/api/*| LambdaEdge
    LambdaEdge -->|"ARC=On"| APIGW1
    LambdaEdge -->|"ARC=Off"| APIGW2
    LambdaEdge -.->|queries| ARC

    APIGW1 -->|JWT valid| AgentProxy1
    AgentProxy1 -->|VPC Endpoint| Runtime1
    Runtime1 -->|VPC Endpoint| Gateway1
    Gateway1 -->|HTTPS + JWT| OrdersAPI1
    OrdersAPI1 -->|invokes| OrdersLambdas1
    OrdersLambdas1 -->|VPC Endpoint| DDB
    OAuthCB1 -->|NAT| AzureAD
    Runtime1 -.->|VPC Endpoint| EP1

    APIGW2 -->|JWT valid| Runtime2
    Runtime2 -->|VPC Endpoint| Gateway2
    Gateway2 -->|HTTPS + JWT| OrdersAPI2
    OrdersAPI2 --> OrdersLambdas2
    OrdersLambdas2 -->|VPC Endpoint| DDB

    style VPC1 fill:#e8f5e9,stroke:#2e7d32
    style VPC2 fill:#e8f5e9,stroke:#2e7d32
    style Private1 fill:#c8e6c9,stroke:#388e3c
    style Private2 fill:#c8e6c9,stroke:#388e3c
    style Edge fill:#e3f2fd,stroke:#1565c0
    style Internet fill:#fff3e0,stroke:#e65100
```

---

## Security Flow — Step by Step (Demo Script)

Use this to walk through the security posture during a demo:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 1: User opens https://d378wato2sz2af.cloudfront.net                   │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 🛡️ WAF (CloudFront)                                                │    │
│  │    • Blocks known malicious IPs (AWS IP Reputation List)            │    │
│  │    • Blocks SQL injection attempts                                  │    │
│  │    • Rate limits: 2000 requests / 5 minutes per IP                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 2: CloudFront serves static frontend from S3                          │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 📡 CloudFront + S3                                                  │    │
│  │    • TLS 1.2 enforced (HTTP → HTTPS redirect)                       │    │
│  │    • S3 bucket: ALL public access blocked                           │    │
│  │    • Access via OAC (Origin Access Control) only                    │    │
│  │    • CORS: only https://d378wato2sz2af.cloudfront.net allowed       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 3: User sends prompt → /api/invoke                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ ⚡ Lambda@Edge (ARC Router)                                         │    │
│  │    • Queries ARC routing control in real-time                       │    │
│  │    • On = route to us-east-1 | Off = route to us-east-2            │    │
│  │    • Failover in < 30 seconds                                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 4: Request hits Agent Proxy HTTP API                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 🔒 JWT Authorizer (Azure Entra ID)                                  │    │
│  │    • Validates token signature against Azure AD JWKS                 │    │
│  │    • Checks audience claim matches app registration                 │    │
│  │    • No token or invalid token → 401 Unauthorized                   │    │
│  │    • Expired token → 401 Unauthorized                               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ════════════════ ENTERS VPC (Private Subnets) ════════════════             │
│                                                                             │
│  STEP 5: Agent Proxy Lambda (VPC-attached)                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ λ Agent Proxy                                                       │    │
│  │    • Runs in private subnet (no internet access)                    │    │
│  │    • Calls AgentCore Runtime via VPC endpoint                       │    │
│  │    • Security Group: egress 443 only                                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 6: AgentCore Runtime (VPC Mode)                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 🤖 AgentCore Runtime (Claude Sonnet 4.5)                            │    │
│  │    • NetworkMode: VPC (ENIs in private subnets)                     │    │
│  │    • Calls Bedrock LLM via bedrock-runtime VPC endpoint             │    │
│  │    • Calls Gateway via bedrock-agentcore.gateway VPC endpoint       │    │
│  │    • Loads MCP tools from Gateway (private path)                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 7: AgentCore Gateway (AWS-managed)                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 🔗 AgentCore Gateway                                                │    │
│  │    • Custom JWT authorizer (validates agent's token)                 │    │
│  │    • Cedar Policy Engine: forbids qty >= 100                        │    │
│  │    • OAuth2 credential provider (delegated user access)             │    │
│  │    • Calls Orders API over AWS backbone (not public internet)       │    │
│  │    • IAM: scoped policy (execute-api + secrets + agentcore only)    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 8: Orders REST API                                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 🛡️ Orders API (REGIONAL + Resource Policy + WAF)                    │    │
│  │    • Resource Policy: ONLY AgentCore Gateway can invoke             │    │
│  │    • Direct access from anywhere else → 403 Forbidden               │    │
│  │    • WAF: IP reputation + SQLi + rate limiting                      │    │
│  │    • JWT Authorizer: validates delegated user token                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 9: Orders Lambda Functions (VPC-attached)                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ λ Orders Lambdas (GET/POST/PUT)                                     │    │
│  │    • Run in private subnets                                         │    │
│  │    • Access DynamoDB via Gateway VPC endpoint (FREE, private)       │    │
│  │    • IAM: scoped to specific DynamoDB table only                    │    │
│  │    • No internet access                                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  STEP 10: DynamoDB (Private)                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 📊 DynamoDB Global Table                                            │    │
│  │    • Accessed only via Gateway VPC endpoint                         │    │
│  │    • Replicated: us-east-1 ↔ us-east-2 (RPO = 0)                   │    │
│  │    • Point-in-Time Recovery enabled                                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### What's blocked at each layer:

| Attack | Blocked By | Response |
|--------|-----------|----------|
| DDoS / rate abuse | WAF (Step 1) | 403 |
| SQL injection | WAF (Step 1, 8) | 403 |
| No authentication | JWT Authorizer (Step 4) | 401 |
| Stolen/expired token | JWT Authorizer (Step 4) | 401 |
| Direct API bypass | Resource Policy (Step 8) | 403 |
| Quantity > 100 | Cedar Policy (Step 7) | Blocked by policy |
| Cross-origin attack | CORS (Step 2) | No CORS headers |
| Data exfiltration | VPC isolation (Steps 5-9) | No internet path |
| Region failure | ARC failover (Step 3) | Auto-route to DR |

| Layer | Control | Effect |
|-------|---------|--------|
| **Edge** | CloudFront + WAF | Blocks malicious IPs, SQLi, rate abuse |
| **API Auth** | JWT Authorizer (Azure AD) | Unauthenticated requests → 401 |
| **Network** | VPC + Private Subnets | No public internet for compute |
| **Endpoints** | 11 VPC PrivateLink endpoints | All AWS API calls stay private |
| **Compute** | Lambda + Runtime in VPC | ENIs in private subnets only |
| **Data** | DynamoDB Gateway Endpoint | No public endpoint access |
| **Secrets** | Interface Endpoint + Scoped IAM | Private access, specific ARNs |
| **CORS** | Restricted to CloudFront domain | Cross-origin attacks blocked |
| **Failover** | ARC + Lambda@Edge | Sub-minute DR activation |
| **Policy** | Cedar Policy Engine | Fine-grained tool-level access control |

---

## Traffic Paths

### ✅ Private Traffic (inside VPC)
- Agent Proxy Lambda → AgentCore Runtime (via `bedrock-agentcore` endpoint)
- Runtime → Gateway (via `bedrock-agentcore.gateway` endpoint)
- Orders Lambdas → DynamoDB (via Gateway endpoint)
- All Lambdas → Secrets Manager (via Interface endpoint)
- Runtime → Bedrock LLM (via `bedrock-runtime` endpoint)
- All Lambdas → CloudWatch Logs (via Interface endpoint)

### ⚠️ Controlled Public Traffic (secured by auth)
- AgentCore Gateway → Orders API (JWT + WAF protected, REGIONAL endpoint)
- OAuth Callback → Azure AD (via NAT Gateway, required for 3-legged auth)
- User → CloudFront (HTTPS, WAF filtered)

---

## Multi-Region Failover

```
Normal Operation (ARC = On):
  User → CloudFront → Lambda@Edge → us-east-1 API

Failover (ARC = Off):
  User → CloudFront → Lambda@Edge → us-east-2 API

Recovery (ARC = On again):
  User → CloudFront → Lambda@Edge → us-east-1 API
```

**Failover time:** < 30 seconds (Lambda@Edge queries ARC on every /api/* request)

---

## Cost (per region, monthly)

| Resource | Cost |
|----------|------|
| NAT Gateway | ~$32 |
| 9 Interface VPC Endpoints | ~$63 |
| WAF WebACL | ~$5 |
| ARC Cluster (shared) | ~$1,800 |
| **Total per region** | **~$100** (excl. ARC) |

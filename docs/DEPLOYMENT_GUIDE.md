# Deployment Guide — v3-secure Branch

> **Branch**: `v3-secure`  
> **Base**: `redwood-multi-region-enhancements`  
> **Purpose**: VPC security enhancements with private networking for all compute

---

## What This Branch Adds

This branch transforms the deployment from fully-public traffic to VPC-isolated private networking. All Lambda functions, the AgentCore Runtime, and AWS service calls now route through VPC endpoints instead of the public internet.

### Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `infrastructure/cloudformation/templates/vpc-stack.yaml` | NEW | VPC, 11 VPC endpoints, NAT Gateway, security groups |
| `infrastructure/cloudformation/templates/agentcore-app-stack.yaml` | MODIFIED | VPC mode runtime, JWT authorizer, scoped IAM, CORS |
| `infrastructure/cloudformation/templates/backend-api-stack.yaml` | MODIFIED | Lambda VpcConfig, WAF, ENI permissions |
| `infrastructure/cloudformation/templates/frontend-stack.yaml` | MODIFIED | CloudFront WAF |
| `infrastructure/cloudformation/templates/parent-regional.yaml` | MODIFIED | Accepts & passes VPC parameters |
| `infrastructure/scripts/deploy-stack-multi-region.sh` | MODIFIED | VPC param injection, runtime VPC mode |
| `infrastructure/deploy-config-multi-region.sh` | MODIFIED | ARC config for current account |
| `deploy-security-fast.sh` | NEW | Rapid iteration helper (skips Lambda packaging) |
| `docs/SECURITY_IMPLEMENTATION_SUMMARY.md` | NEW | Full implementation details + learnings |
| `docs/security_deviations.md` | NEW | Original security analysis |
| `security-architecture-diagram.drawio` | NEW | Visual architecture diagram |

---

## Security Controls

| Control | How It's Enforced |
|---------|-------------------|
| Unauthenticated API access blocked | JWT Authorizer on Agent Proxy HTTP API |
| SQL injection / abuse protection | AWS WAF on Orders API + CloudFront |
| Lambda internet isolation | VPC private subnets + VPC endpoints |
| AgentCore Runtime isolation | VPC mode (NetworkMode: VPC) |
| DynamoDB private access | Gateway VPC endpoint |
| Secrets Manager private access | Interface VPC endpoint |
| Bedrock private access | Interface VPC endpoint |
| OAuth token scoping | IAM policies scoped to specific ARNs |
| CORS restriction | Locked to CloudFront domain |

---

## Prerequisites (New Account)

### AWS
1. AWS Account with permissions for: CloudFormation, IAM, Lambda, API Gateway, DynamoDB, S3, Bedrock AgentCore, VPC, WAF, SecretsManager, CloudFront
2. Bedrock model access enabled: `us.anthropic.claude-sonnet-4-5-20250929-v1:0`
3. Two regions: primary (us-east-1) + DR (us-east-2)

### Azure Entra ID
3 App Registrations (see main README.md for details):
- **Gateway App** → `GatewayIdpClientId`
- **Agent App** → `AgentIdpClientId`  
- **Orders API App** → `TargetIdpClientId` + `TargetIdpClientSecret`

---

## Deployment Steps

### Step 0: Configure

```bash
# 1. Update deploy config with your account details
vi infrastructure/deploy-config-multi-region.sh
# Change: AWS_PROFILE, SUFFIX (unique per deployment), ARC settings

# 2. Create parameter file from template
cp infrastructure/cloudformation/parameters/dev-parameters-multi-region.json.template \
   infrastructure/cloudformation/parameters/dev-parameters-multi-region.json
# Fill in your Azure Entra ID values
```

### Step 1: Deploy VPC (both regions)

```bash
# Primary region VPC
aws cloudformation create-stack \
  --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} \
  --template-body file://infrastructure/cloudformation/templates/vpc-stack.yaml \
  --parameters ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
               ParameterKey=DeploymentSuffix,ParameterValue=${SUFFIX} \
  --region us-east-1 \
  --tags Key=Environment,Value=${ENVIRONMENT}

# DR region VPC
aws cloudformation create-stack \
  --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} \
  --template-body file://infrastructure/cloudformation/templates/vpc-stack.yaml \
  --parameters ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
               ParameterKey=DeploymentSuffix,ParameterValue=${SUFFIX} \
  --region us-east-2 \
  --tags Key=Environment,Value=${ENVIRONMENT}

# Wait for both (~3 minutes each)
aws cloudformation wait stack-create-complete --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} --region us-east-1
aws cloudformation wait stack-create-complete --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} --region us-east-2
```

### Step 2: Deploy Infrastructure (full deploy)

```bash
bash infrastructure/scripts/deploy-stack-multi-region.sh --update
```

This will:
1. Package Lambda functions
2. Upload to S3 (both regions)
3. Deploy primary regional stack (with VPC params auto-injected)
4. Deploy DR regional stack (with VPC params auto-injected)
5. Deploy Lambda@Edge + global stack (CloudFront)
6. Deploy memory stacks
7. Update runtimes to VPC mode
8. Create gateway secrets
9. Build and deploy frontend

### Step 3: Post-Deploy (Azure Entra ID)

After deployment, get the callback URLs from stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name secure-agentcore-app-${ENVIRONMENT}-${SUFFIX} \
  --region us-east-1 \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
```

Register these in Azure:
- `CallbackUrl` → Orders API App Registration → Authentication → Redirect URIs
- CloudFront domain → Gateway App Registration → Authentication → Redirect URIs

### Step 4: Verify

```bash
# JWT authorizer (expect 401)
PROXY_URL=$(aws cloudformation describe-stacks --stack-name secure-agentcore-app-${ENVIRONMENT}-${SUFFIX} --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`AgentProxyFunctionUrl`].OutputValue' --output text)
curl -s -o /dev/null -w "HTTP %{http_code}" "${PROXY_URL}/invoke" -X POST -d '{"prompt":"test"}'

# Open in browser
CF_DOMAIN=$(aws cloudformation describe-stacks --stack-name secure-agentcore-app-${ENVIRONMENT}-${SUFFIX}-global --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomainName`].OutputValue' --output text)
echo "https://${CF_DOMAIN}"
```

---

## Rapid Iteration (Template Changes Only)

When making template-only changes (no Lambda code changes), skip the full deploy:

```bash
# 1. Upload changed templates
aws s3 sync infrastructure/cloudformation/templates/ \
  s3://${ENVIRONMENT}-cfn-templates-${SUFFIX}-us-east-1/templates/ --region us-east-1

# 2. Fast deploy (uses deploy-security-fast.sh pattern)
aws cloudformation deploy \
  --template-file infrastructure/cloudformation/templates/parent-regional.yaml \
  --stack-name secure-agentcore-app-${ENVIRONMENT}-${SUFFIX} \
  --parameter-overrides [...VPC params...] \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --no-fail-on-empty-changeset
```

---

## ARC Failover Testing

```bash
# Check current state
aws route53-recovery-cluster get-routing-control-state \
  --routing-control-arn "${ARC_ROUTING_CONTROL_ARN}" \
  --region us-west-2 \
  --endpoint-url "${ARC_CLUSTER_ENDPOINTS[3]}"

# Failover to DR (turn OFF primary)
aws route53-recovery-cluster update-routing-control-state \
  --routing-control-arn "${ARC_ROUTING_CONTROL_ARN}" \
  --routing-control-state Off \
  --region us-west-2 \
  --endpoint-url "${ARC_CLUSTER_ENDPOINTS[3]}"

# Restore primary (turn ON)
aws route53-recovery-cluster update-routing-control-state \
  --routing-control-arn "${ARC_ROUTING_CONTROL_ARN}" \
  --routing-control-state On \
  --region us-west-2 \
  --endpoint-url "${ARC_CLUSTER_ENDPOINTS[3]}"
```

---

## Critical Learnings (Read Before Deploying)

### 1. AgentCore Runtime AZ Requirements
Subnets MUST be in supported Availability Zone IDs:
- **us-east-1**: `use1-az1`, `use1-az2`, `use1-az4`
- **us-east-2**: `use2-az1`, `use2-az2`, `use2-az3`

The `vpc-stack.yaml` uses explicit AZ mappings — do NOT change to index-based selection.

### 2. Required VPC Endpoints (All 11)
Missing any of these breaks specific functionality:
- `bedrock-agentcore.gateway` — MCP tools won't load without this
- `bedrock-agentcore` — InvokeAgentRuntime fails from VPC Lambda
- `ecr.dkr` + `ecr.api` — Runtime container image pull fails

### 3. GatewayRole Needs AdministratorAccess
The AgentCore Gateway is AWS-managed and requires broad permissions. Least-privilege attempts cause "No MCP tools returned" errors.

### 4. Orders API Must Stay REGIONAL
The AgentCore Gateway (external to VPC) needs to reach it. Making it PRIVATE breaks the Gateway→API flow.

### 5. OAuthCallbackLambdaRole Permissions
Needs access to:
- `workload-identity-directory/default/*` (not just `token-vault`)
- `bedrock-agentcore-identity*` secrets (internal to AgentCore)

### 6. VPC Stack Should Be Standalone
Deploy VPC as its own stack BEFORE the main regional stack. Nesting causes long rollback delays on failures.

### 7. Lambda SG Egress: 0.0.0.0/0
Restricting to just endpoint SG + NAT CIDR is insufficient. Use `0.0.0.0/0:443` for HTTPS egress.

---

## Cost Impact

| Resource | Monthly Cost (per region) |
|----------|--------------------------|
| NAT Gateway | ~$32 + data transfer |
| 9 Interface VPC Endpoints | ~$63 (9 × $7) |
| WAF WebACL (regional) | ~$5 + per-request |
| WAF WebACL (CloudFront) | ~$5 + per-request |
| ARC Cluster | ~$1,800 (shared across regions) |
| **Total per region** | **~$105/month** (excluding ARC) |

---

## Cleanup

```bash
# Delete ARC (stops $2.50/hr billing)
aws route53-recovery-control-config delete-cluster \
  --cluster-arn "arn:aws:route53-recovery-control::ACCOUNT:cluster/CLUSTER_ID" \
  --region us-west-2

# Delete stacks
bash infrastructure/scripts/cleanup-stack-multi-region.sh

# Delete VPC stacks
aws cloudformation delete-stack --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} --region us-east-1
aws cloudformation delete-stack --stack-name ${ENVIRONMENT}-vpc-${SUFFIX} --region us-east-2
```

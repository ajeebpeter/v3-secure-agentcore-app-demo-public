#!/bin/bash
# Fast deploy — security enhancements only (no Lambda repackaging)
set -e
export AWS_PAGER=""

REGION="us-east-1"
STACK="secure-agentcore-app-dev-v3redwood"
TEMPLATES_DIR="infrastructure/cloudformation/templates"
PARAM_FILE="infrastructure/cloudformation/parameters/dev-parameters-multi-region.json"

# Build parameter overrides from JSON file
PARAM_OVERRIDES=()
while IFS= read -r line; do
    PARAM_OVERRIDES+=("$line")
done < <(python3 -c "
import json
with open('${PARAM_FILE}') as f:
    params = json.load(f)
for p in params:
    if 'ParameterKey' in p and 'ParameterValue' in p:
        print(f\"{p['ParameterKey']}={p['ParameterValue']}\")
")

# Add deployment-derived parameters
PARAM_OVERRIDES+=("TemplatesBucket=dev-cfn-templates-v3redwood-us-east-1")
PARAM_OVERRIDES+=("LambdaCodeBucket=dev-lambda-code-v3redwood-us-east-1")
PARAM_OVERRIDES+=("DeploymentSuffix=v3redwood")
PARAM_OVERRIDES+=("CreateDDBTable=true")
PARAM_OVERRIDES+=("DRRegion=us-east-2")
PARAM_OVERRIDES+=("CloudFrontDomain=d378wato2sz2af.cloudfront.net")

# VPC parameters from standalone VPC stack
PARAM_OVERRIDES+=("VpcId=vpc-0a4c6c81f198aec76")
PARAM_OVERRIDES+=("PrivateSubnet1Id=subnet-07abc32f6307ea12c")
PARAM_OVERRIDES+=("PrivateSubnet2Id=subnet-07d17d734f3596e7f")
PARAM_OVERRIDES+=("LambdaSecurityGroupId=sg-0c7076fef649dcfa5")
PARAM_OVERRIDES+=("ExecuteApiEndpointId=vpce-0c24d9204a82cdf14")

echo "Deploying ${STACK} with VPC security enhancements..."
echo "  VPC: vpc-0a4c6c81f198aec76"
echo "  Subnets: use1-az4, use1-az1 (supported by AgentCore)"

aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/parent-regional.yaml" \
    --stack-name "${STACK}" \
    --parameter-overrides "${PARAM_OVERRIDES[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --no-fail-on-empty-changeset

echo "✅ Deploy complete!"

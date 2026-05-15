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
PARAM_OVERRIDES+=("CloudFrontDomain=YOUR_CLOUDFRONT_DOMAIN")

# VPC parameters from standalone VPC stack
PARAM_OVERRIDES+=("VpcId=YOUR_VPC_ID")
PARAM_OVERRIDES+=("PrivateSubnet1Id=YOUR_PRIVATE_SUBNET_1_ID")
PARAM_OVERRIDES+=("PrivateSubnet2Id=YOUR_PRIVATE_SUBNET_2_ID")
PARAM_OVERRIDES+=("LambdaSecurityGroupId=YOUR_LAMBDA_SG_ID")
PARAM_OVERRIDES+=("ExecuteApiEndpointId=YOUR_VPCE_ID")

# Gateway ARN for API resource policy lockdown
GW_ARN=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`AgentRuntimeArn`].OutputValue' --output text 2>/dev/null | sed 's/runtime/gateway/' || echo "")
# Look up actual gateway ARN
GW_ID=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`GatewayId`].OutputValue' --output text 2>/dev/null || echo "")
if [ -n "${GW_ID}" ] && [ "${GW_ID}" != "None" ]; then
    GW_ARN=$(aws bedrock-agentcore-control get-gateway --gateway-identifier "${GW_ID}" --region "${REGION}" --query 'gatewayArn' --output text 2>/dev/null || echo "")
    if [ -n "${GW_ARN}" ] && [ "${GW_ARN}" != "None" ]; then
        PARAM_OVERRIDES+=("GatewayArn=${GW_ARN}")
        echo "  GatewayArn: ${GW_ARN}"
    fi
fi

echo "Deploying ${STACK} with VPC security enhancements..."
echo "  VPC: ${VPC_ID:-see PARAM_OVERRIDES}"
echo "  Subnets: use1-az4, use1-az1 (supported by AgentCore)"

aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/parent-regional.yaml" \
    --stack-name "${STACK}" \
    --parameter-overrides "${PARAM_OVERRIDES[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --no-fail-on-empty-changeset

echo "✅ Deploy complete!"

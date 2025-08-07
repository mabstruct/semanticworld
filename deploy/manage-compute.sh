#!/bin/bash
export AWS_PROFILE=semanticworld

# =============================================================================
# semantic-world Infrastructure Management Script
# Layer 2: Compute Stack (GPU ML Instances)
# =============================================================================

set -e  # Exit on any error

# Configuration
PROJECT_NAME="semanticworld"
STACK_LAYER="compute"
TEMPLATE_FILE="semanticworld-compute.yaml"
DEFAULT_REGION="eu-central-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/${TEMPLATE_FILE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_gpu() {
    echo -e "${PURPLE}[GPU]${NC} $1"
}

log_cost() {
    echo -e "${CYAN}[COST]${NC} $1"
}

show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [ENVIRONMENT] [OPTIONS]

COMMANDS:
    create      Create/update the compute stack
    delete      Delete the compute stack
    status      Show stack status and instance information
    validate    Validate CloudFormation template
    outputs     Show stack outputs
    connect     Show connection information for instances
    monitor     Show GPU and system monitoring information
    cost        Show cost estimation and tracking
    help        Show this help message

ENVIRONMENTS:
    dev         Development environment (g4dn.xlarge)
    test        Test environment (t3.medium - no GPU)
    staging     Staging environment  
    prod        Production environment

OPTIONS:
    --region REGION         AWS region (default: eu-central-1)
    --profile PROFILE       AWS profile to use
    --dry-run              Validate only, don't create/update
    --force-delete         Force delete stack even if in failed state
    --no-wait              Don't wait for stack operations to complete
    --instance-type TYPE   Override instance type for deployment
    --subnet SUBNET        Override subnet selection (private-1|private-2)
    --storage-size SIZE    Override additional storage size in GB

EXAMPLES:
    $0 create dev                           # Create dev compute stack
    $0 create dev --instance-type t3.large  # Create with different instance type
    $0 status dev                           # Show dev stack status and GPU info
    $0 connect dev                          # Show connection commands
    $0 monitor dev                          # Show GPU and system monitoring
    $0 cost dev                            # Show cost information
    $0 delete dev --force-delete           # Force delete dev stack
    $0 validate                            # Validate template syntax

NOTES:
    - Instances are deployed in private subnets for security
    - Use Session Manager for secure access (no SSH keys required)
    - GPU instances automatically include CUDA and ML frameworks
    - Cost monitoring includes hourly, daily, and monthly estimates
    - All instances include CloudWatch monitoring and logging

EOF
}

get_stack_name() {
    local environment=$1
    echo "${PROJECT_NAME}-${environment}-${STACK_LAYER}"
}

get_parameter_file() {
    local environment=$1
    echo "${SCRIPT_DIR}/${TEMPLATE_FILE%.*}-parameters-${environment}.json"
}

get_aws_region() {
    if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
        echo "$AWS_DEFAULT_REGION"
    elif aws configure get region >/dev/null 2>&1; then
        aws configure get region
    else
        echo "$DEFAULT_REGION"
    fi
}

check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI first."
        exit 1
    fi
}

check_template_exists() {
    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        log_error "Template file not found: $TEMPLATE_PATH"
        exit 1
    fi
}

check_parameters_exist() {
    local environment=$1
    local param_file=$(get_parameter_file "$environment")
    
    if [[ ! -f "$param_file" ]]; then
        log_error "Parameter file not found: $param_file"
        log_info "Available parameter files:"
        ls -1 "${SCRIPT_DIR}"/*-compute-parameters-*.json 2>/dev/null || log_warning "No parameter files found"
        exit 1
    fi
}

check_networking_dependency() {
    local environment=$1
    local networking_stack="${PROJECT_NAME}-${environment}-networking"
    
    log_info "Checking networking layer dependency..."
    
    if ! aws cloudformation describe-stacks --stack-name "$networking_stack" >/dev/null 2>&1; then
        log_error "Networking stack not found: $networking_stack"
        log_error "Please deploy the networking layer first using:"
        log_error "  ./manage-networking.sh create $environment"
        exit 1
    fi
    
    local networking_status=$(aws cloudformation describe-stacks \
        --stack-name "$networking_stack" \
        --query 'Stacks[0].StackStatus' \
        --output text)
    
    if [[ "$networking_status" != "CREATE_COMPLETE" && "$networking_status" != "UPDATE_COMPLETE" ]]; then
        log_error "Networking stack is not in a ready state: $networking_status"
        log_error "Please ensure networking stack is deployed and stable first"
        exit 1
    fi
    
    log_success "Networking layer dependency satisfied"
}

wait_for_stack_operation() {
    local stack_name=$1
    local operation=$2
    local max_wait_time=1800  # 30 minutes
    local wait_time=0
    local poll_interval=30
    
    log_info "Waiting for $operation to complete (timeout: ${max_wait_time}s)..."
    
    while [[ $wait_time -lt $max_wait_time ]]; do
        local status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "STACK_NOT_FOUND")
        
        case $status in
            *_COMPLETE)
                log_success "$operation completed successfully"
                return 0
                ;;
            *_FAILED|ROLLBACK_COMPLETE)
                log_error "$operation failed with status: $status"
                show_stack_events "$stack_name" 10
                return 1
                ;;
            *_IN_PROGRESS)
                echo -n "."
                ;;
            STACK_NOT_FOUND)
                if [[ "$operation" == "delete" ]]; then
                    log_success "Stack deleted successfully"
                    return 0
                else
                    log_error "Stack not found"
                    return 1
                fi
                ;;
            *)
                log_warning "Unknown status: $status"
                ;;
        esac
        
        sleep $poll_interval
        wait_time=$((wait_time + poll_interval))
    done
    
    log_error "Operation timed out after ${max_wait_time} seconds"
    return 1
}

show_stack_events() {
    local stack_name=$1
    local count=${2:-20}
    
    log_info "Recent stack events:"
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --max-items "$count" \
        --query 'StackEvents[?ResourceStatus!=`null`].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output table 2>/dev/null || log_warning "Could not retrieve stack events"
}

get_instance_id() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`ComputeInstanceId`].OutputValue' \
        --output text 2>/dev/null || echo ""
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

validate_template() {
    log_info "Validating CloudFormation template..."
    
    check_template_exists
    
    if aws cloudformation validate-template --template-body "file://$TEMPLATE_PATH" >/dev/null 2>&1; then
        log_success "Template validation passed"
        
        # Show template summary
        log_info "Template summary:"
        aws cloudformation validate-template \
            --template-body "file://$TEMPLATE_PATH" \
            --query 'Description' \
            --output text 2>/dev/null || echo "No description available"
        
        aws cloudformation validate-template \
            --template-body "file://$TEMPLATE_PATH" \
            --query 'Parameters[].{Parameter:ParameterKey,Type:Type,Default:DefaultValue}' \
            --output table 2>/dev/null || echo "No parameters info available"
        return 0
    else
        log_error "Template validation failed"
        aws cloudformation validate-template --template-body "file://$TEMPLATE_PATH"
        return 1
    fi
}

create_stack() {
    local environment=$1
    local dry_run=${2:-false}
    local no_wait=${3:-false}
    local instance_type=${4:-""}
    local subnet_selection=${5:-""}
    local storage_size=${6:-""}
    
    local stack_name=$(get_stack_name "$environment")
    local param_file=$(get_parameter_file "$environment")
    
    log_info "Creating/updating compute stack: $stack_name"
    
    check_template_exists
    check_parameters_exist "$environment"
    check_networking_dependency "$environment"
    
    # Validate template first
    if ! validate_template; then
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_success "Dry run completed - template is valid and dependencies are satisfied"
        return 0
    fi
    
    # Check if stack exists
    local stack_exists=false
    if aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
        stack_exists=true
        log_info "Stack exists - will update"
    else
        log_info "Stack doesn't exist - will create"
    fi
    
    # Prepare parameters
    local cmd_args=(
        --stack-name "$stack_name"
        --template-file "$TEMPLATE_PATH"
        --parameter-overrides
            "ProjectName=$PROJECT_NAME"
            "Environment=$environment"
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
        --tags
            "Key=Project,Value=$PROJECT_NAME"
            "Key=Environment,Value=$environment"
            "Key=Layer,Value=$STACK_LAYER"
            "Key=ManagedBy,Value=CloudFormation"
    )
    
    # Add parameter overrides if specified
    if [[ -n "$instance_type" ]]; then
        cmd_args+=("InstanceType=$instance_type")
        log_info "Using custom instance type: $instance_type"
    fi
    
    if [[ -n "$subnet_selection" ]]; then
        cmd_args+=("SubnetSelection=$subnet_selection")
        log_info "Using custom subnet: $subnet_selection"
    fi
    
    if [[ -n "$storage_size" ]]; then
        cmd_args+=("AdditionalStorageSize=$storage_size")
        log_info "Using custom storage size: ${storage_size}GB"
    fi
    
    if [[ "$no_wait" == "false" ]]; then
        cmd_args+=(--no-fail-on-empty-changeset)
    fi
    
    log_info "Executing: aws cloudformation deploy ${cmd_args[*]}"
    
    if aws cloudformation deploy "${cmd_args[@]}"; then
        if [[ "$no_wait" == "false" ]]; then
            log_success "Stack deployment completed"
            show_stack_outputs "$stack_name"
            show_connection_info "$stack_name"
            show_cost_estimation "$stack_name"
        else
            log_info "Stack deployment initiated (not waiting for completion)"
        fi
        return 0
    else
        log_error "Stack deployment failed"
        show_stack_events "$stack_name"
        return 1
    fi
}

delete_stack() {
    local environment=$1
    local force_delete=${2:-false}
    local no_wait=${3:-false}
    
    local stack_name=$(get_stack_name "$environment")
    
    # Check if stack exists
    if ! aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
        log_warning "Stack $stack_name not found"
        return 0
    fi
    
    local current_status=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' \
        --output text)
    
    log_info "Current stack status: $current_status"
    
    # Show cost summary before deletion
    log_cost "Final cost summary before deletion:"
    show_cost_estimation "$stack_name"
    
    # Handle failed stacks
    if [[ "$current_status" == *"FAILED"* ]] && [[ "$force_delete" == "true" ]]; then
        log_warning "Stack is in failed state - attempting forced deletion"
        
        # Try to terminate any running instances first
        local instance_id=$(get_instance_id "$stack_name")
        if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
            log_warning "Attempting to terminate instance: $instance_id"
            aws ec2 terminate-instances --instance-ids "$instance_id" 2>/dev/null || true
            sleep 30
        fi
    fi
    
    log_info "Deleting stack: $stack_name"
    
    if aws cloudformation delete-stack --stack-name "$stack_name"; then
        if [[ "$no_wait" == "false" ]]; then
            wait_for_stack_operation "$stack_name" "delete"
        else
            log_info "Stack deletion initiated (not waiting for completion)"
        fi
        return 0
    else
        log_error "Failed to initiate stack deletion"
        return 1
    fi
}

show_stack_status() {
    local environment=$1
    local stack_name=$(get_stack_name "$environment")
    
    log_info "Stack status for: $stack_name"
    
    # Check if stack exists
    if ! aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
        log_warning "Stack not found: $stack_name"
        return 1
    fi
    
    # Show stack summary
    log_info "Stack information:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].[StackName,StackStatus,CreationTime,LastUpdatedTime]' \
        --output table
    
    # Show recent events
    show_stack_events "$stack_name" 10
    
    # Show resource summary
    log_info "Stack resources:"
    aws cloudformation describe-stack-resources \
        --stack-name "$stack_name" \
        --query 'StackResources[].[LogicalResourceId,ResourceType,ResourceStatus]' \
        --output table
    
    # Show instance details if available
    local instance_id=$(get_instance_id "$stack_name")
    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        log_info "Instance details:"
        aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType,PrivateIpAddress,LaunchTime]' \
            --output table
        
        # Show GPU information if GPU instance
        show_gpu_status "$instance_id"
    fi
}

show_stack_outputs() {
    local stack_name=$1
    
    log_info "Stack outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[].[OutputKey,OutputValue,Description]' \
        --output table 2>/dev/null || log_warning "No outputs found or stack doesn't exist"
}

show_connection_info() {
    local stack_name=$1
    
    log_info "Connection information:"
    
    local instance_id=$(get_instance_id "$stack_name")
    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        local region=$(get_aws_region)
        
        echo
        log_success "Instance ID: $instance_id"
        log_success "Session Manager connection:"
        echo "  aws ssm start-session --target $instance_id --region $region"
        echo
        log_info "Alternative connection methods:"
        echo "  # Port forwarding for Jupyter (if running):"
        echo "  aws ssm start-session --target $instance_id --document-name AWS-StartPortForwardingSession --parameters 'portNumber=[8888],localPortNumber=[8888]' --region $region"
        echo
        echo "  # File transfer:"
        echo "  aws s3 cp file.txt s3://your-bucket/  # Upload to S3 first"
        echo "  # Then download on instance via Session Manager"
        echo
    else
        log_warning "No instance found in stack outputs"
    fi
}

show_gpu_status() {
    local instance_id=$1
    
    # Check if instance is GPU-enabled
    local instance_type=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].InstanceType' \
        --output text 2>/dev/null)
    
    if [[ "$instance_type" == g4dn* ]]; then
        log_gpu "GPU-enabled instance detected: $instance_type"
        log_gpu "To check GPU status, connect to instance and run:"
        echo "  nvidia-smi"
        echo "  nvtop  # For real-time GPU monitoring"
        echo
        log_gpu "GPU monitoring metrics available in CloudWatch:"
        echo "  Namespace: semanticworld/<environment>/GPU"
        echo "  Metrics: GPUUtilization, GPUMemoryUtilization, GPUTemperature"
    else
        log_info "Non-GPU instance: $instance_type"
    fi
}

show_monitoring_info() {
    local environment=$1
    local stack_name=$(get_stack_name "$environment")
    
    log_info "Monitoring information for: $stack_name"
    
    local instance_id=$(get_instance_id "$stack_name")
    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log_warning "No instance found"
        return 1
    fi
    
    # Show instance state
    local instance_state=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    log_info "Instance state: $instance_state"
    
    if [[ "$instance_state" != "running" ]]; then
        log_warning "Instance is not running - monitoring data may be limited"
        return 0
    fi
    
    # Show recent CPU metrics
    log_info "Recent CPU utilization (last hour):"
    aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 \
        --metric-name CPUUtilization \
        --dimensions Name=InstanceId,Value="$instance_id" \
        --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 300 \
        --statistics Average,Maximum \
        --output table 2>/dev/null || log_warning "No CPU metrics available yet"
    
    # Show GPU metrics if available
    local instance_type=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].InstanceType' \
        --output text)
    
    if [[ "$instance_type" == g4dn* ]]; then
        log_gpu "Recent GPU utilization (last hour):"
        aws cloudwatch get-metric-statistics \
            --namespace "semanticworld/${environment}/GPU" \
            --metric-name GPUUtilization \
            --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
            --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
            --period 300 \
            --statistics Average,Maximum \
            --output table 2>/dev/null || log_warning "No GPU metrics available yet (may take a few minutes after launch)"
    fi
    
    # Show log group information
    local log_group="semanticworld-${environment}-compute"
    log_info "CloudWatch Logs:"
    echo "  Log Group: $log_group"
    echo "  View logs: aws logs describe-log-streams --log-group-name $log_group"
}

show_cost_estimation() {
    local stack_name=$1
    
    log_cost "Cost estimation:"
    
    # Get hourly cost from stack outputs
    local hourly_cost=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`EstimatedHourlyCost`].OutputValue' \
        --output text 2>/dev/null)
    
    if [[ -n "$hourly_cost" && "$hourly_cost" != "None" ]]; then
        # Remove the $ sign for calculations
        local cost_value=$(echo "$hourly_cost" | sed 's/\$//g')
        
        # Calculate daily and monthly costs
        local daily_cost=$(echo "scale=2; $cost_value * 24" | bc)
        local monthly_cost=$(echo "scale=2; $cost_value * 24 * 30" | bc)
        
        echo "  Hourly: $hourly_cost"
        echo "  Daily: \$${daily_cost}"
        echo "  Monthly: \$${monthly_cost}"
        echo
        
        # Show storage costs if additional volume exists
        local additional_storage=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].Parameters[?ParameterKey==`AdditionalStorageSize`].ParameterValue' \
            --output text 2>/dev/null)
        
        if [[ -n "$additional_storage" && "$additional_storage" != "0" ]]; then
            local storage_monthly=$(echo "scale=2; $additional_storage * 0.08" | bc)  # $0.08/GB/month for gp3
            echo "  Additional Storage (${additional_storage}GB): \$${storage_monthly}/month"
        fi
        
        log_cost "Note: Costs are estimates based on on-demand pricing in us-east-1"
        log_cost "Actual costs may vary by region and usage patterns"
    else
        log_warning "Cost information not available"
    fi
}

# =============================================================================
# MAIN SCRIPT LOGIC
# =============================================================================

main() {
    # Parse command line arguments
    local command=""
    local environment=""
    local aws_region=""
    local aws_profile=""
    local dry_run=false
    local force_delete=false
    local no_wait=false
    local instance_type=""
    local subnet_selection=""
    local storage_size=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            create|delete|status|validate|outputs|connect|monitor|cost|help)
                command=$1
                shift
                ;;
            dev|test|staging|prod)
                environment=$1
                shift
                ;;
            --region)
                aws_region=$2
                shift 2
                ;;
            --profile)
                aws_profile=$2
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --force-delete)
                force_delete=true
                shift
                ;;
            --no-wait)
                no_wait=true
                shift
                ;;
            --instance-type)
                instance_type=$2
                shift 2
                ;;
            --subnet)
                subnet_selection=$2
                shift 2
                ;;
            --storage-size)
                storage_size=$2
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set AWS CLI options
    if [[ -n "$aws_region" ]]; then
        export AWS_DEFAULT_REGION="$aws_region"
    fi
    
    if [[ -n "$aws_profile" ]]; then
        export AWS_PROFILE="$aws_profile"
    fi
    
    # Check for required tools
    check_aws_cli
    
    # Execute command
    case $command in
        create)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for create command"
                show_usage
                exit 1
            fi
            create_stack "$environment" "$dry_run" "$no_wait" "$instance_type" "$subnet_selection" "$storage_size"
            ;;
        delete)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for delete command"
                show_usage
                exit 1
            fi
            delete_stack "$environment" "$force_delete" "$no_wait"
            ;;
        status)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for status command"
                show_usage
                exit 1
            fi
            show_stack_status "$environment"
            ;;
        outputs)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for outputs command"
                show_usage
                exit 1
            fi
            show_stack_outputs $(get_stack_name "$environment")
            ;;
        connect)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for connect command"
                show_usage
                exit 1
            fi
            show_connection_info $(get_stack_name "$environment")
            ;;
        monitor)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for monitor command"
                show_usage
                exit 1
            fi
            show_monitoring_info "$environment"
            ;;
        cost)
            if [[ -z "$environment" ]]; then
                log_error "Environment required for cost command"
                show_usage
                exit 1
            fi
            show_cost_estimation $(get_stack_name "$environment")
            ;;
        validate)
            validate_template
            ;;
        help)
            show_usage
            ;;
        "")
            log_error "No command specified"
            show_usage
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"

#!/bin/bash

# =============================================================================
# langsam-cloud Infrastructure Management Script
# Layer 1: VPN & Networking Stack
# =============================================================================

set -e  # Exit on any error

# Configuration
PROJECT_NAME="semantic-world"
STACK_LAYER="networking"
TEMPLATE_FILE="01-networking.yaml"
DEFAULT_REGION="eu-central-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/${TEMPLATE_FILE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [ENVIRONMENT] [OPTIONS]

COMMANDS:
    create      Create/update the networking stack
    delete      Delete the networking stack
    status      Show stack status and resources
    validate    Validate CloudFormation template
    outputs     Show stack outputs
    help        Show this help message

ENVIRONMENTS:
    dev         Development environment
    test        Test environment
    staging     Staging environment  
    prod        Production environment

OPTIONS:
    --region REGION     AWS region (default: eu-central-1)
    --profile PROFILE   AWS profile to use
    --dry-run          Validate only, don't create/update
    --force-delete     Force delete stack even if in failed state
    --no-wait          Don't wait for stack operations to complete

EXAMPLES:
    $0 create dev                    # Create dev networking stack
    $0 delete dev --force-delete     # Force delete dev stack
    $0 status prod                   # Show prod stack status
    $0 validate                      # Validate template syntax

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
        ls -1 "${SCRIPT_DIR}"/*-parameters-*.json 2>/dev/null || log_warning "No parameter files found"
        exit 1
    fi
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

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

validate_template() {
    log_info "Validating CloudFormation template..."
    
    check_template_exists
    
    if aws cloudformation validate-template --template-body "file://$TEMPLATE_PATH" >/dev/null 2>&1; then
        log_success "Template validation passed"
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
    
    local stack_name=$(get_stack_name "$environment")
    local param_file=$(get_parameter_file "$environment")
    
    log_info "Creating/updating networking stack: $stack_name"
    
    check_template_exists
    check_parameters_exist "$environment"
    
    # Validate template first
    if ! validate_template; then
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_success "Dry run completed - template is valid"
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
    
    # Deploy stack
    local cmd_args=(
        --stack-name "$stack_name"
        --template-file "$TEMPLATE_PATH"
        --parameter-overrides
            "ProjectName=$PROJECT_NAME"
            "Environment=$environment"
        --capabilities CAPABILITY_IAM
        --tags
            "Key=Project,Value=$PROJECT_NAME"
            "Key=Environment,Value=$environment"
            "Key=Layer,Value=$STACK_LAYER"
            "Key=ManagedBy,Value=CloudFormation"
    )
    
    if [[ "$no_wait" == "false" ]]; then
        cmd_args+=(--no-fail-on-empty-changeset)
    fi
    
    log_info "Executing: aws cloudformation deploy ${cmd_args[*]}"
    
    if aws cloudformation deploy "${cmd_args[@]}"; then
        if [[ "$no_wait" == "false" ]]; then
            log_success "Stack deployment completed"
            show_stack_outputs "$stack_name"
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
    
    # Handle failed stacks
    if [[ "$current_status" == *"FAILED"* ]] && [[ "$force_delete" == "true" ]]; then
        log_warning "Stack is in failed state - attempting forced deletion"
        
        # Try to delete resources manually if needed
        # This would need to be implemented based on specific failure patterns
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
}

show_stack_outputs() {
    local stack_name=$1
    
    log_info "Stack outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[].[OutputKey,OutputValue,Description]' \
        --output table 2>/dev/null || log_warning "No outputs found or stack doesn't exist"
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
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            create|delete|status|validate|outputs|help)
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
            create_stack "$environment" "$dry_run" "$no_wait"
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

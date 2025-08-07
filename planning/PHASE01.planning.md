# PHASE 01: ML Compute Node Setup - Planning and Requirements

## Overview
This document outlines the planning and implementation strategy for setting up a GPU-enabled compute node (g4dn.xlarge EC2 instance) for machine learning tasks, built on top of the existing semantic-world networking foundation layer.

## Project Context
Based on the existing infrastructure and project methods analysis:

### Current Infrastructure Foundation
- **Networking Layer**: semantic-world VPC with private/public subnets across 2 AZs
- **Security**: Default security groups with controlled access patterns
- **NAT Gateways**: Dual NAT gateways for high availability private subnet internet access
- **Management Approach**: Systematic CloudFormation-based infrastructure as code
- **Project Standards**: BDD-driven development with comprehensive validation

### Development Philosophy Alignment
Following the established project methods from `AIDEVLEARNINGS.md` and `AIAWSLEARNINGS.md`:
- **Layer-by-Layer Development**: Building compute layer on proven networking foundation
- **Professional Management Scripts**: Consistent with existing `manage-networking.sh` patterns
- **Security-First**: Private subnet deployment with least-privilege access
- **Cost-Aware**: Automated lifecycle management with teardown capabilities
- **Validation-Driven**: Comprehensive testing and monitoring integration

## Objectives

### Primary Goals
1. **GPU Compute Instance**: Deploy g4dn.xlarge EC2 instance for ML workloads
2. **Private Subnet Security**: Instance deployed in existing private subnets
3. **Foundation Integration**: Leverage existing VPC, subnets, and security groups
4. **Management Automation**: Create `manage-compute.sh` following established patterns
5. **Scalability Preparation**: Design for future API proxy integration

### Success Criteria
- [ ] g4dn.xlarge instance running in private subnet
- [ ] Instance accessible via secure connection patterns
- [ ] Management script supporting full lifecycle (create/delete/status/validate)
- [ ] Cost-efficient operations with proper teardown capabilities
- [ ] Documentation following project standards

## Technical Requirements

### Infrastructure Components

#### EC2 Instance Specifications
- **Instance Type**: g4dn.xlarge (1 NVIDIA T4 GPU, 4 vCPUs, 16 GB RAM)
- **AMI**: Deep Learning AMI (Ubuntu) with pre-configured ML frameworks
- **Storage**: 
  - Root volume: 50GB gp3 (expandable for model storage)
  - Optional: Additional EBS volume for data/models if needed
- **Subnet Placement**: One of the existing private subnets (PrivateSubnet1 or PrivateSubnet2)

#### Security Configuration
- **Security Group**: New ML-specific security group
  - SSH access from bastion/management subnet patterns
  - Internal VPC communication for future API integration
  - HTTPS/HTTP for model serving (future phase)
- **IAM Role**: ML compute role with:
  - CloudWatch logging permissions
  - S3 access for model/data storage
  - Systems Manager Session Manager for secure access
  - ECR access for container images (future use)

#### Network Integration
- **VPC**: Use existing semantic-world VPC
- **Subnets**: Deploy in existing private subnets
- **Internet Access**: Via existing NAT gateways
- **DNS**: Internal DNS resolution within VPC

### Management Script Requirements

#### `manage-compute.sh` Features
Following the proven patterns from `manage-networking.sh`:

```bash
# Command structure
./manage-compute.sh [COMMAND] [ENVIRONMENT] [OPTIONS]

# Supported commands
create      # Create/update compute stack
delete      # Delete compute stack  
status      # Show instance and stack status
validate    # Validate CloudFormation template
outputs     # Show stack outputs and instance details
help        # Usage documentation

# Environment support
dev|test|staging|prod

# Options
--region REGION         # AWS region override
--profile PROFILE       # AWS profile override
--dry-run              # Validate without deployment
--force-delete         # Force stack deletion
--no-wait              # Don't wait for completion
--instance-type TYPE   # Override instance type for testing
```

#### Additional Compute-Specific Features
- **GPU Monitoring**: NVIDIA GPU utilization and memory status
- **Instance Health**: CPU, memory, disk usage monitoring
- **ML Environment**: Verify CUDA, frameworks, and ML libraries
- **Connection Info**: Provide secure connection methods (Session Manager)
- **Cost Tracking**: Instance cost estimation and usage monitoring

## Implementation Strategy

### Phase 1A: Foundation Setup (Week 1)
1. **Template Development**
   - Create `semanticworld-compute.yaml` CloudFormation template
   - Define parameters following networking layer patterns
   - Implement proper resource naming and tagging
   - Add cross-stack references to networking layer

2. **Security Design**
   - Design ML-specific security group
   - Create IAM role for compute instances
   - Plan Session Manager access patterns
   - Document security boundaries

### Phase 1B: Management Automation (Week 1-2)
1. **Script Development**
   - Create `manage-compute.sh` following established patterns
   - Implement all standard lifecycle operations
   - Add compute-specific monitoring and diagnostics
   - Include cost estimation features

2. **Parameter Management**
   - Create environment-specific parameter files
   - Support multiple instance types for testing
   - Configure storage and networking options

### Phase 1C: Validation and Testing (Week 2)
1. **Infrastructure Testing**
   - Deploy to dev environment
   - Validate GPU functionality
   - Test Session Manager connectivity
   - Verify ML framework installation

2. **Integration Testing**
   - Test cross-stack dependencies
   - Validate networking connectivity
   - Test management script operations
   - Performance baseline establishment

### Phase 1D: Documentation and Handoff (Week 2)
1. **Documentation**
   - Update architecture documentation
   - Create operational runbooks
   - Document cost optimization strategies
   - ML workload deployment guide

2. **Validation**
   - Complete BDD scenarios
   - Cost analysis and optimization
   - Security review
   - Operational readiness assessment

## Risk Assessment and Mitigation

### Technical Risks
- **GPU Driver Compatibility**: Use proven Deep Learning AMI
- **Cost Overrun**: Implement automatic shutdown policies
- **Network Connectivity**: Leverage proven networking layer
- **Instance Availability**: Plan for spot instance options

### Operational Risks
- **Manual Operations**: Comprehensive automation via management script
- **Security Gaps**: Follow established security patterns
- **Monitoring Blind Spots**: Implement comprehensive CloudWatch monitoring
- **Backup/Recovery**: Document instance and data backup strategies

## Dependencies and Prerequisites

### Infrastructure Dependencies
- [ ] Networking layer deployed and operational
- [ ] VPC and subnets available
- [ ] NAT gateways functional
- [ ] Security groups and IAM roles accessible

### Technical Prerequisites
- [ ] AWS CLI configured with appropriate permissions
- [ ] CloudFormation templates validated
- [ ] Parameter files configured for target environments
- [ ] Management scripts tested in development

### Knowledge Requirements
- [ ] Understanding of existing networking architecture
- [ ] GPU instance management experience
- [ ] ML framework requirements
- [ ] AWS cost optimization strategies

## Success Metrics

### Infrastructure Metrics
- **Deployment Time**: < 10 minutes for stack creation
- **Instance Health**: 99.5% uptime during operation
- **Network Performance**: < 10ms latency within VPC
- **GPU Utilization**: Monitoring and alerting configured

### Cost Metrics
- **Daily Cost**: Tracked and reported
- **Idle Detection**: Automatic notification for unused instances
- **Right-sizing**: Instance type optimization recommendations
- **Teardown Efficiency**: Complete resource cleanup in < 5 minutes

### Operational Metrics
- **Management Script Coverage**: 100% lifecycle operation support
- **Documentation Completeness**: All operations documented
- **Error Recovery**: Automated failure detection and recovery
- **Security Compliance**: All security requirements verified

## Next Steps

### Immediate Actions (This Week)
1. **Create CloudFormation Template**: Start with basic g4dn.xlarge template
2. **Develop Management Script**: Base on networking script patterns
3. **Design Security Groups**: ML-specific security requirements
4. **Parameter Configuration**: Environment-specific settings

### Short-term Actions (Next 2 Weeks)  
1. **Deploy Development Instance**: Test basic functionality
2. **Validate ML Environment**: Ensure CUDA and frameworks work
3. **Implement Monitoring**: CloudWatch and custom metrics
4. **Cost Optimization**: Implement automatic shutdown policies

### Medium-term Planning (Next Month)
1. **Scaling Strategies**: Auto Scaling Group for multiple instances
2. **Container Integration**: Docker and ECR integration
3. **API Gateway Preparation**: Foundation for future API access
4. **Data Pipeline Integration**: S3 and data processing workflows

## Documentation Standards

Following project documentation standards:
- **Technical Specifications**: Detailed in CloudFormation templates
- **Operational Procedures**: Step-by-step in management scripts
- **Architecture Decisions**: Documented with rationale
- **BDD Scenarios**: Testable behavior specifications
- **Runbooks**: Operational maintenance procedures

## Conclusion

This phase establishes the compute foundation for ML workloads while maintaining the high standards of security, automation, and documentation established by the networking layer. The approach ensures cost-effective operations, comprehensive monitoring, and seamless integration with existing infrastructure.

The deliverable will be a production-ready compute layer that serves as the foundation for the future API integration phase, following all established project methodologies and best practices.

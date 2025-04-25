# Shift API Automation 

This documentation describes the end-to-end migration workflow implementation. The workflow consists of multiple steps including site creation, resource group setup, blueprint creation and verification, compliance checks, migration triggering, and status monitoring. Each of these steps is modularized into distinct functions that are called sequentially based on the configuration provided in the JSON payload.
 
## Pre-Requisites
Before running the application, update the IP address in the config.yml file where your shift is running. For example, adjust the API URI as shown below:

    # config.yml
    api:
        uri: "http://10.61.187.230"
Ensure that the IP address in the URI matches the environment where the service is deployed.

## Overview

The migration workflow implementation automates the process of migrating virtual machines between different site environments. It uses a well-defined JSON payload to capture configuration and migration parameters. Based on these parameters, the workflow performs a series of operations that ensure the resources are correctly provisioned, validated, and migrated.
The key responsibilities of this system include:

    •	Creating and verifying source and destination sites: Ensures that both the source and destination infrastructures are in place and ready.
    •	Provisioning resource groups: Links the sites by creating a resource group needed for migration.
    •	Creating blueprints and running compliance checks: Sets up migration blueprints whose compliance and configuration are validated before the actual migration.
    •	Triggering the migration: Executes the migration based on the blueprint and monitors the job for successful completion.
 
## Payload Structure and Mapping
The JSON payload that drives the migration workflow is stored on GitHub. Please refer to the following link for the payload configuration:

JSON Payload: [https://github.com/NetApp/shift_api_automation/blob/shift_api_automation/shift_api_automation.json](https://github.com/NetApp/shift_api_automation/blob/shift_api_automation/shift_api_automation.json)


### Field Descriptions
    1.execution_name: A label to identify the execution run.
    2.shift_username & shift_password: Credentials required to create a session for shift.
    3.site names (source_site_name, destination_site_name): Names provided to create and track source and destination sites.
    4.Config Objects (vmware_config, ontap_config, hyperv_config): Configuration for interacting with respective virtualization or storage management APIs.
    5.migration_mode: Specifies the migration strategy (e.g., "clone_based_migration").
    6.vm_details: Array containing virtual machine information such as hardware details, boot configuration, and network interfaces.
    7.Additional resource/group names, mappings, and credentials: Further parameters that guide the blueprint and resource group creation stages.
    8.The JSON payload uses several "do_" flags to control which sections of the migration workflow should be executed. These flags enable flexibility by allowing users to skip specific steps when necessary. However, when a step is skipped, corresponding backup values need to be provided to ensure that later stages of the workflow have the necessary information. Here's how each flag and its associated backup field work:
        •	do_create_sites: 
            -	When true, the workflow creates both the source and destination sites.
            -	When false, site creation is skipped and the user must provide:
            backup_source_site_id and backup_destination_site_id
            so the workflow has the required IDs for later steps.
        •	do_add_resource_group:
            -	When true, the workflow invokes the function to create and validate a resource group.
            -	When false, this step is skipped and the user must supply backup_resource_group_id 
            to link the source and destination sites.
        •	do_create_blueprint:
            -	When true, the workflow creates a new blueprint based on the resource group(s) provided.
            -	When false, blueprint creation is skipped and the user must provide backup_blueprint_id, so that subsequent compliance checks and migration triggers can refer to an existing blueprint.
        •	do_trigger_migration:
            -	When true, the workflow triggers the migration by executing the blueprint and returns an execution ID.
            -	When false, the migration execution is skipped, which might be useful for compliance or validation-only scenarios.
        •	do_check_status:
            -	When true, the workflow checks the final migration status and validates job steps through status checks.
            -	When false, the detailed status verification step is skipped.

 
## Key Workflow Components
### Site Creation and Verification
This is the first stage in the migration process. It is accomplished by the create_sites function and involves:

    •	Source Site Creation: Using the Site API, a source site is created. On success, the site details and discovery status are verified.
    •	Destination Site Creation: Similarly, a destination site is created and its details validated using the appropriate API endpoints (for Hyper-V in this case).
The function logs errors if any of these steps fail and returns the site IDs for subsequent operations.

### Resource Group Creation
Once both sites are ready, the next step is to create a resource group that logically ties these sites together. This is performed by the add_resource_group function:

    •	It uses the Protection Group API to create a resource group.
    •	The creation is validated by checking whether a valid resource group ID is returned.
    •	Proper logging is in place to record success or failure.
### Blueprint Creation and Compliance Check
After resource group creation, the blueprint is established using the create_blueprint_with_resource_groups function. This process includes:

    •	Blueprint Setup: Based on the migration mode, a blueprint is created with the association of one or more resource groups.
    •	Verification of Blueprint Details: Once created, the blueprint details are fetched and verified.
    •	Compliance Check: The run_compliance_check function triggers a compliance check to ensure that the blueprint meets all necessary requirements before proceeding. A short delay is introduced to allow the blueprint setup to settle.
### Migration Execution and Monitoring
The actual migration is triggered by executing the blueprint and then monitored for completion through the following steps:

    •	Migration Trigger: The trigger_migration function uses the blueprint API to execute the migration. On success, an execution ID is returned.
    •	Status Verification: The migration status is then checked with the check_migration_status function. This step involves:
        -	Verifying the blueprint status to confirm migration completion.
        -	Checking the job steps using the Job Monitoring API to ensure that all tasks in the migration process are successful.

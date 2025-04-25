import logging
from utils.json_parser import json_parser
from api.api_modules.session import SessionAPI
from conftest import shift_api_automation_config
from add_site import create_sites
from add_resource_group import add_resource_group
from create_blueprint import create_blueprint
from run_compliance_check import run_compliance_check
from trigger_migration import trigger_migration
from check_migration_status import check_migration_status
from log_config import shift_api_automation_logger
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.site import SiteAPI
from api.api_modules.protection_group import ProtectionGroupAPI
# from utils.vcenter_utils import VcenterUtils


logger = shift_api_automation_logger()

def full_migration_workflow(session_id, migration_config):
    migration_mode = migration_config.get("migration_mode")
    logger.info(f"Starting execution for: {migration_config.get('execution_name')}")

    source_site_id = None
    destination_site_id = None
    resource_group_ids = None
    blueprint_id = None
    execution_id = None
    source_site_name = None
    destination_site_name = None
    blueprint_api = BluePrintAPI(logger, migration_config.get("shift_server_ip"))
    resource_group_api = ProtectionGroupAPI(logger, migration_config.get("shift_server_ip"))
    # vcenter_utils = VcenterUtils(logger, migration_config)
    # vcenter_utils.create_vm_connection()

    if migration_config.get("do_create_sites", True):
        try:
            source_site_id, destination_site_id = create_sites(session_id, migration_config)
        except Exception as e:
            logger.error(f"Create sites failed: {e}")
    else:
        logger.info("Skipping site creation as per configuration.")

    if migration_config.get("do_add_resource_group", True):
        try:
            source_site_name = migration_config.get("source_site_name")
            destination_site_name = migration_config.get("destination_site_name")
            resource_group_ids = add_resource_group(session_id, migration_config, source_site_name, destination_site_name)
            logger.info(f"Resource Groups created with id: {resource_group_ids}")
        except Exception as e:
            logger.error(f"Add resource group failed: {e}")
    else:
        logger.info("Skipping resource group creation as per configuration.")

    if migration_config.get("do_create_blueprint", True):
        try:
            blueprint_id = create_blueprint(session_id, migration_config, migration_mode)
        except Exception as e:
            logger.error(f"Create blueprint failed: {e}")
    else:
        logger.info("Skipping blueprint creation as per configuration.")

    if migration_config.get("do_compliance", True):
        try:
            blueprint_name = migration_config.get("blueprint_name")
            run_compliance_check(session_id, migration_config.get("shift_server_ip"), blueprint_name)
        except Exception as e:
            logger.error(f"Compliance check failed: {e}")

    if migration_config.get("do_prepare_vm", True):
        try:
            vm_on_list = list()
            vm_details_json = migration_config.get("vm_details")
            if vm_details_json is None:
                logger.error("Missing vm_details entry.")
                exit(1)
            for vm_entry in vm_details_json:
                vm_name = vm_entry.get("name")
                if not vm_name:
                    logger.error("Missing vm name in vm_details entry.")
                    exit(1)
                if vm_name not in vm_on_list:
                    vm_on_list.append(vm_name)
            # vcenter_utils.wait_for_power_on(vm_on_list)
            if not blueprint_id:
                blueprint_name = migration_config.get("blueprint_name")
                blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
            if blueprint_id:
                prepare_vm_status = blueprint_api.wait_for_prepare_vm_execution(session_id, blueprint_id, logger)
            else:
                logger.error("No blueprint id available, cannot check status.")
        except Exception as e:
            logger.error(f"Prepare VM check failed: {e}")

    if migration_config.get("do_trigger_migration", True):
        try:
            vm_off_list = list()
            vm_details_json = migration_config.get("vm_details")
            if vm_details_json is None:
                logger.error("Missing vm_details entry.")
                exit(1)
            for vm_entry in vm_details_json:
                vm_name = vm_entry.get("name")
                if not vm_name:
                    logger.error("Missing vm name in vm_details entry.")
                    exit(1)
                if vm_name not in vm_off_list:
                    vm_off_list.append(vm_name)
            # vcenter_utils.wait_for_power_off(vm_off_list)
            blueprint_name = migration_config.get("blueprint_name")
            if blueprint_id and not prepare_vm_status:
                logger.error("Prepare VM failed, cannot trigger migration.")
            else:
                execution_id = trigger_migration(session_id, migration_config.get("shift_server_ip"), blueprint_name, migration_mode)
        except Exception as e:
            logger.error(f"Trigger migration failed: {e}")
    else:
        logger.info("Skipping migration trigger as per configuration.")

    if migration_config.get("do_check_status", True):
        try:
            if blueprint_id and not prepare_vm_status:
                logger.info("Skipping migration status check.")
            else:
                if not execution_id:
                    execution_id = migration_config.get("execution_id")
                blueprint_name = migration_config.get("blueprint_name")
                final_status = check_migration_status(session_id, blueprint_name, execution_id, migration_config.get("shift_server_ip"))
                logger.info(f"Final migration status for blueprint {blueprint_name}: {final_status}")
        except Exception as e:
            logger.error(f"Check migration status failed: {e}")
    else:
        logger.info("Skipping status check as per configuration.")

if __name__ == "__main__":
    config_data = json_parser(shift_api_automation_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, migration_config in enumerate(executions, 1):
            logger.info(f"Starting workflow {idx}")
            shift_username = migration_config.get("shift_username")
            shift_password = migration_config.get("shift_password")
            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for migration index {idx}. Skipping this migration.")
                continue

            shift_api = SessionAPI(logger, migration_config.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)

            full_migration_workflow(session_id, migration_config)

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during migration workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

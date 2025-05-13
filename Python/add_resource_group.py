from utils.json_parser import json_parser
from api.api_modules.session import SessionAPI
from api.api_modules.protection_group import ProtectionGroupAPI
from conftest import add_resource_group_config
from log_config import get_add_resource_group_logger

logger = get_add_resource_group_logger()
logger.info("Add resource group workflow started")

def add_resource_group(session_id, add_resource_group_config, source_site_name, dest_site_name):
    protection_group_api = ProtectionGroupAPI(logger, add_resource_group_config.get('shift_server_ip'))
    resource_group_ids = protection_group_api.create_resource_group(
        session_id,
        add_resource_group_config,
        source_site_name,
        dest_site_name,
        logger
    )

    if resource_group_ids:
        for resource_group_id in resource_group_ids:
            logger.info(f"Resource group created with id: {resource_group_id}")
    else:
        logger.error("Failed to create any resource group using POST /api/setup/protectionGroup API")

    return resource_group_ids

if __name__ == "__main__":
    config_data = json_parser(add_resource_group_config.ifile)
    executions = config_data.get("executions", [])

    try:
        for idx, add_resource_group_config_data in enumerate(executions, 1):
            logger.info(f"Starting resource group workflow {idx}")
            shift_username = add_resource_group_config_data.get("shift_username")
            shift_password = add_resource_group_config_data.get("shift_password")
            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for resource group index {idx}. Skipping this resource group.")
                continue

            source_site_name = add_resource_group_config_data.get("source_site_name")
            dest_site_name = add_resource_group_config_data.get("destination_site_name")
            if not source_site_name or not dest_site_name:
                logger.error(f"Missing site IDs for resource group index {idx}. Skipping this resource group.")
                continue

            shift_api = SessionAPI(logger, add_resource_group_config_data.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for resource group index {idx}. Skipping this resource group.")
                continue

            add_resource_group(session_id, add_resource_group_config_data, source_site_name, dest_site_name)

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during resource group workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")
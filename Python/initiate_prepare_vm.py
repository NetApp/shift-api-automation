import logging
import time
import log_config
from utils.db_utils import MongoDBClient
from utils.json_parser import json_parser
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.job_monitoring import JobMonitoring
from api.api_modules.protection_group import ProtectionGroupAPI
from api.api_modules.session import SessionAPI
from api.api_modules.site import SiteAPI
from conftest import initiate_prepare_vm_config
from log_config import initiate_prepare_vm_logger

logger = initiate_prepare_vm_logger()
logger.setLevel(logging.INFO)

def initiate_prepare_vm(session_id, shift_server_ip, blueprint_name):
    blueprint_api = BluePrintAPI(logger, shift_server_ip)
    blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
    execution_id = blueprint_api.initiate_prepare_vm(session_id, logger, blueprint_id)
    if not execution_id:
        logger.error(
            f"Initiating Prepare VM operation for blueprint {blueprint_name} was not successful using POST run compliance API"
        )
    else:
        logger.info(f"Initiated Prepare VM for blueprint {blueprint_name} with execution id: {execution_id}")
    prepare_vm_status = blueprint_api.wait_for_prepare_vm_execution(session_id, blueprint_id, logger)
    logger.info(f"Status of Prepare VM is {prepare_vm_status} for blueprint {blueprint_id}")
    if not prepare_vm_status:
        logger.error(f"Prepare VM for blueprint id {blueprint_id} did not complete successfully.")
    else:
        logger.info(f"Prepare VM successfully completed for execution id {blueprint_id}")
    return execution_id, prepare_vm_status

if __name__ == "__main__":
    config_data = json_parser(initiate_prepare_vm_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, initiate_prepare_vm_config in enumerate(executions, 1):
            final_status = ""
            logger.info(f"Starting Initiating Prepare VM workflow {idx}")

            shift_username = initiate_prepare_vm_config.get("shift_username")
            shift_password = initiate_prepare_vm_config.get("shift_password")
            blueprint_name = initiate_prepare_vm_config.get("blueprint_name")

            if not shift_username or not shift_password or not blueprint_name:
                logger.error(f"Missing required details for Initiating Prepare VM index {idx}. Skipping this Initiating Prepare VM.")
                continue

            shift_api = SessionAPI(logger, initiate_prepare_vm_config.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for Initiating Prepare VM index {idx}. Skipping this Initiating Prepare VM.")
                continue

            execution_id, prepare_vm_status = initiate_prepare_vm(session_id, initiate_prepare_vm_config.get("shift_server_ip"), blueprint_name)
            if execution_id:
                if prepare_vm_status:
                    final_status = "Success"
                else:
                    final_status = "Failed"
                logger.info(f"Initiated Prepare VM and status is {final_status} for index {idx}")
            else:
                logger.error(f"Initiation of Prepare VM failed for index {idx}")

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during Initiating Prepare VM workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

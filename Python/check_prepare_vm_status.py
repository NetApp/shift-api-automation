import logging
from utils.json_parser import json_parser
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.job_monitoring import JobMonitoring
from api.api_modules.session import SessionAPI
from conftest import check_prepare_vm_status_config
from log_config import check_prepare_vm_status_logger

logger = check_prepare_vm_status_logger()
logger.setLevel(logging.INFO)

def check_prepare_vm_status(session_id, blueprint_name, shift_server_ip):
    blueprint_api = BluePrintAPI(logger, shift_server_ip)
    blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
    prepare_vm_status = blueprint_api.wait_for_prepare_vm_execution(session_id, blueprint_id, logger)
    logger.info(f"Status of Prepare VM is {prepare_vm_status} for blueprint {blueprint_id}")
    if not prepare_vm_status:
        logger.error(f"Prepare VM for blueprint id {blueprint_id} did not complete successfully.")
    else:
        logger.info(f"Prepare VM successfully completed for execution id {blueprint_id}")
    return prepare_vm_status

if __name__ == "__main__":
    config_data = json_parser(check_prepare_vm_status_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, prepare_vm_config_data in enumerate(executions, 1):
            logger.info(f"Starting prepare VM workflow {idx}")

            shift_username = prepare_vm_config_data.get("shift_username")
            shift_password = prepare_vm_config_data.get("shift_password")
            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for prepare VM index {idx}. Skipping this prepare VM.")
                continue

            blueprint_name = prepare_vm_config_data.get("blueprint_name")
            if not blueprint_name:
                logger.error(f"Missing blueprint id for prepare VM check index {idx}. Skipping this prepare VM.")
                continue

            shift_api = SessionAPI(logger, prepare_vm_config_data.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for prepare VM index {idx}. Skipping this prepare VM.")
                continue

            status = check_prepare_vm_status(session_id, blueprint_name, prepare_vm_config_data.get("shift_server_ip"))

            shift_api.end_drom_session(session_id)

    except Exception as ex:
        logger.error(f"An error occurred during prepare VMs: {ex}")

    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

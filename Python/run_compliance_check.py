import logging
import time
from utils.json_parser import json_parser
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.session import SessionAPI
from conftest import run_compliance_check_config
from log_config import run_compliance_check_logger

logger = run_compliance_check_logger()
logger.setLevel(logging.INFO)

def run_compliance_check(session_id, shift_server_ip, blueprint_name):
    blueprint_api = BluePrintAPI(logger, shift_server_ip)
    time.sleep(20)

    blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
    compliance_status, compliance_task_id = blueprint_api.run_compliance_check_on_blueprint(session_id, blueprint_id, logger)
    if not compliance_task_id:
        logger.error(
            f"Compliance check request for blueprint {blueprint_id} failed using POST /api/setup/compliance/drplan/{blueprint_id}/checkrequest API"
        )
    else:
        logger.info(f"Compliance check initiated with task id: {compliance_task_id}")

    compliance_status_flag, compliance_result = blueprint_api.verify_compliance_check_status(session_id, compliance_task_id, logger)
    if not compliance_status_flag:
        logger.error(f"Compliance status check failed for compliance id {compliance_task_id}")
    else:
        logger.info(f"Compliance check passed with result: {compliance_result}")

    return compliance_task_id

if __name__ == "__main__":
    config_data = json_parser(run_compliance_check_config.ifile)
    executions = config_data.get("executions", [])

    try:
        for idx, run_compliance_check_config_data in enumerate(executions, 1):
            logger.info(f"Starting complaince check workflow {idx}")

            shift_username = run_compliance_check_config_data.get("shift_username")
            shift_password = run_compliance_check_config_data.get("shift_password")
            blueprint_name = run_compliance_check_config_data.get("blueprint_name")

            if not shift_username or not shift_password or not blueprint_name:
                logger.error(f"Missing credentials or blueprint_name for run_compliance_check index {idx}. Skipping this run_compliance_check.")
                continue

            shift_api = SessionAPI(logger, run_compliance_check_config_data.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for run_compliance_check index {idx}. Skipping this run_compliance_check.")
                continue

            compliance_task_id = run_compliance_check(session_id, run_compliance_check_config_data.get("shift_server_ip"), blueprint_name)
            if compliance_task_id:
                logger.info(f"Compliance check completed for blueprint {blueprint_name} with task id {compliance_task_id}")
            else:
                logger.error(f"Compliance check failed for blueprint {blueprint_name}")

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during run_compliance_check workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

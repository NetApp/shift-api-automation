import logging
from utils.json_parser import json_parser
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.job_monitoring import JobMonitoring
from api.api_modules.session import SessionAPI
from conftest import check_migration_status_config
from log_config import check_migration_status_logger

logger = check_migration_status_logger()
logger.setLevel(logging.INFO)

def check_migration_status(session_id, blueprint_name, execution_id, shift_server_ip):
    blueprint_api = BluePrintAPI(logger, shift_server_ip)
    job_monitoring_api = JobMonitoring(logger, shift_server_ip)

    blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
    status = blueprint_api.verify_blueprint_status(session_id, blueprint_id, logger)
    logger.info(f"Status of Blueprint is {status} for blueprint {blueprint_id}")

    job_success = job_monitoring_api.validate_job_steps_is_success(session_id, execution_id, logger)
    if not job_success:
        logger.error(f"Job steps for execution id {execution_id} did not complete successfully.")
    else:
        logger.info(f"Job steps successfully completed for execution id {execution_id}")
    return status

if __name__ == "__main__":
    config_data = json_parser(check_migration_status_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, check_migration_config in enumerate(executions, 1):
            logger.info(f"Starting migration status check workflow {idx}")

            shift_username = check_migration_config.get("shift_username")
            shift_password = check_migration_config.get("shift_password")
            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for migration status check index {idx}. Skipping this migration status check.")
                continue

            blueprint_name = check_migration_config.get("blueprint_name")
            execution_id = check_migration_config.get("execution_id")
            if not blueprint_name or not execution_id:
                logger.error(f"Missing blueprint or execution id for migration status check index {idx}. Skipping this migration status check.")
                continue

            shift_api = SessionAPI(logger, check_migration_config.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for migration status check index {idx}. Skipping this migration status check.")
                continue

            status = check_migration_status(session_id, blueprint_name, execution_id, check_migration_config.get("shift_server_ip"))
            logger.info(f"Final migration status for index {idx}: {status}")

            shift_api.end_drom_session(session_id)

    except Exception as ex:
        logger.error(f"An error occurred during migration status checks: {ex}")

    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

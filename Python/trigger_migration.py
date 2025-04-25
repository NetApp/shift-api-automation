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
from conftest import trigger_migration_config
from log_config import trigger_migration_logger

logger = trigger_migration_logger()
logger.setLevel(logging.INFO)

def trigger_migration(session_id, shift_server_ip, blueprint_name, migration_mode):
    blueprint_api = BluePrintAPI(logger, shift_server_ip)
    blueprint_id = blueprint_api.get_blueprint_id_by_name(session_id, blueprint_name, logger)
    execution_id = blueprint_api.execute_blueprint(session_id, logger, blueprint_id, execution_type=migration_mode)
    if not execution_id:
        logger.error(
            f"Triggering Migration operation for blueprint {blueprint_name} was not successful using POST run compliance API"
        )
    else:
        logger.info(f"Migration triggered for blueprint {blueprint_name} with execution id: {execution_id}")
    return execution_id

if __name__ == "__main__":
    config_data = json_parser(trigger_migration_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, migration_config in enumerate(executions, 1):
            logger.info(f"Starting trigger migration workflow {idx}")

            shift_username = migration_config.get("shift_username")
            shift_password = migration_config.get("shift_password")
            blueprint_name = migration_config.get("blueprint_name")
            migration_mode = migration_config.get("migration_mode")

            if not shift_username or not shift_password or not blueprint_name:
                logger.error(f"Missing required details for migration index {idx}. Skipping this migration.")
                continue

            shift_api = SessionAPI(logger, migration_config.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for migration index {idx}. Skipping this migration.")
                continue

            execution_id = trigger_migration(session_id, migration_config.get("shift_server_ip"), blueprint_name, migration_mode)
            if execution_id:
                logger.info(f"Migration triggered successfully for migration index {idx}")
            else:
                logger.error(f"Migration trigger failed for migration index {idx}")

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during migration workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

import logging
from utils.json_parser import json_parser
from api.api_modules.blueprint import BluePrintAPI
from api.api_modules.session import SessionAPI
from conftest import create_blueprint_config
from log_config import create_blueprint_logger

logger = create_blueprint_logger()
logger.setLevel(logging.INFO)

def create_blueprint(session_id, create_blueprint_config, migration_mode):
    blueprint_api = BluePrintAPI(logger, create_blueprint_config.get("shift_server_ip"))
    blueprint_id = blueprint_api.create_blueprint(session_id, create_blueprint_config, logger, workflow_type=migration_mode)
    if blueprint_id:
        logger.info(f"Blueprint created with id: {blueprint_id}")
    else:
        logger.error("Blueprint creation failed using POST /api/setup/compliance/drplan API")
        return None

    blueprint_details = blueprint_api.get_blueprint_by_id(session_id, blueprint_id, logger)
    if not blueprint_details:
        logger.error(f"Blueprint details for blueprint {blueprint_id} are not present using GET /api/setup/compliance/drplan API")
    else:
        logger.info(f"Verified blueprint details: {blueprint_details}")
    return blueprint_id

if __name__ == "__main__":
    config_data = json_parser(create_blueprint_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, create_blueprint_config_data in enumerate(executions, 1):
            logger.info(f"Starting blueprint creation workflow {idx}")

            shift_username = create_blueprint_config_data.get("shift_username")
            shift_password = create_blueprint_config_data.get("shift_password")
            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for create blueprint index {idx}. Skipping this create blueprint.")
                continue

            migration_mode = create_blueprint_config_data.get("migration_mode", "full")

            shift_api = SessionAPI(logger, create_blueprint_config_data.get("shift_server_ip"))
            session_id = shift_api.create_drom_session(shift_username, shift_password)
            if not session_id:
                logger.error(f"Failed to create session for create blueprint index {idx}. Skipping this create blueprint.")
                continue

            blueprint_id = create_blueprint(session_id, create_blueprint_config_data, migration_mode)
            if blueprint_id:
                logger.info(f"Successfully processed blueprint creation for create blueprint index {idx}")
            else:
                logger.error(f"Blueprint creation unsuccessful for create blueprint index {idx}")

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during blueprint creation workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

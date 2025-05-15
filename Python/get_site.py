import logging
from conftest import get_site_config
from utils.json_parser import json_parser
from api.api_modules.site import SiteAPI
from api.api_modules.session import SessionAPI
from log_config import get_site_logger

logger = get_site_logger()
logger.info("Get Site workflow started")
logger.setLevel(logging.INFO)
ch = logging.StreamHandler()
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
ch.setFormatter(formatter)
logger.addHandler(ch)

def get_site_details(session_id, get_site_config_data):
    result = False
    site_api = SiteAPI(logger, get_site_config_data.get('shift_server_ip'))
    site_details = site_api.get_site(session_id, logger)
    if not site_details:
        logger.error("Failed to fetch site details")
        result = False
    else:
        logger.info(f"Site details fetched successfully")
        logger.info(f"Site details: {site_details}")
        result = True
    return result


if __name__ == "__main__":
    config_data = json_parser(get_site_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, get_site_config_data in enumerate(executions, 1):
            logger.info(f"Starting get site workflow {idx}")
            shift_username = get_site_config_data.get("shift_username")
            shift_password = get_site_config_data.get("shift_password")

            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for get site index {idx}. Skipping this get site.")
                continue

            shift_api = SessionAPI(logger, get_site_config_data.get('shift_server_ip'))
            session_id = shift_api.create_drom_session(shift_username, shift_password)

            site_result_status = get_site_details(session_id, get_site_config_data)

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred while fetching site details: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

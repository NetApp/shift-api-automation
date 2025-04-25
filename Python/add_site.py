import logging
from conftest import add_site_config
from utils.json_parser import json_parser
from api.api_modules.site import SiteAPI
from api.api_modules.session import SessionAPI
from log_config import get_add_site_logger

logger = get_add_site_logger()
logger.info("Get Site workflow started")
logger.setLevel(logging.INFO)
ch = logging.StreamHandler()
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
ch.setFormatter(formatter)
logger.addHandler(ch)

def create_sites(session_id, add_site_config_data):
    source_site_id, destination_site_id = None, None
    site_api = SiteAPI(logger, add_site_config_data.get('shift_server_ip'))
    source_site_id = site_api.add_site(session_id, add_site_config_data, logger, site_type="source")
    if not source_site_id:
        logger.error("Source site creation failed using POST /api/setup/site")
    else:
        logger.info(f"Source site created with id: {source_site_id}")
        source_site_details = site_api.get_vmware_site_details_by_id(session_id, source_site_id, logger)
        if not source_site_details:
            logger.error("Source site details not present using GET /api/setup/site API")
        else:
            logger.info(f"Source site details: {source_site_details}")

        source_discovery_status = site_api.wait_for_site_discovery(session_id, source_site_id, logger, site_type="source")
        if not source_discovery_status:
            logger.error("Source site discovery completion failed using GET /api/setup/site/discoverystatus API")
        else:
            logger.info("Source site discovery completed successfully")

    destination_site_id = site_api.add_site(session_id, add_site_config_data, logger, site_type="destination")
    if not destination_site_id:
        logger.error("Destination site creation failed using POST /api/setup/site API")
    else:
        logger.info(f"Destination site created with id: {destination_site_id}")

        destination_site_details = site_api.get_hyperv_site_details_by_id(session_id, destination_site_id, logger)
        if not destination_site_details:
            logger.error("Destination site details not present using GET /api/setup/site API")
        else:
            logger.info(f"Destination site details: {destination_site_details}")

        destination_discovery_status = site_api.wait_for_site_discovery(session_id, destination_site_id, logger, site_type="destination")
        if not destination_discovery_status:
            logger.error("Destination site discovery completion failed using GET /api/setup/site/discoverystatus API")
        else:
            logger.info("Destination site discovery completed successfully")

    return source_site_id, destination_site_id


if __name__ == "__main__":
    config_data = json_parser(add_site_config.ifile)
    executions = config_data.get("executions", [])
    try:
        for idx, add_site_config_data in enumerate(executions, 1):
            logger.info(f"Starting add site workflow {idx}")
            shift_username = add_site_config_data.get("shift_username")
            shift_password = add_site_config_data.get("shift_password")

            if not shift_username or not shift_password:
                logger.error(f"Missing credentials for add site index {idx}. Skipping this add site.")
                continue

            shift_api = SessionAPI(logger, add_site_config_data.get('shift_server_ip'))
            session_id = shift_api.create_drom_session(shift_username, shift_password)

            source_id, destination_id = create_sites(session_id, add_site_config_data)

            shift_api.end_drom_session(session_id)
    except Exception as ex:
        logger.error(f"An error occurred during add site workflows: {ex}")
    finally:
        logger.info("Please find the logs of the execution in the latest file of the logs folder")

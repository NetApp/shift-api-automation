import json
import time

from api_wrapper import APIWrapper
from utils.parse_json import convert_to_defaultdict


class SiteAPI:

    def __init__(self, logger, shift_server_ip):
        self.uri = shift_server_ip
        self.api = APIWrapper(logger)

    def add_site(self, session_id, migration_config, logger, site_type='source'):
        logger.info(f"Creating {site_type} site using POST api/setup/site API for data")
        url = self.uri + ":3700/api/setup/site"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        if not site_type:
            return None

        source_payload = {
            "name": migration_config['source_site_name'],
            "connectorId": "connector_id",
            "sitePurpose": {"_id": "1"},
            "location": {"_id": "1"},
            "virtualizationEnvironments": [
                {
                    "provider": {"_id": "1"},
                    "version": "7",
                    "credentials": {
                        "endPoint": migration_config['vmware_config']['endpoint'],
                        "loginId": migration_config['vmware_config']['username'],
                        "password": migration_config['vmware_config']['password'],
                        "skipSSLValidation": migration_config['vmware_config']['skip_vmware_sll_validation']
                    }
                }
            ],
            "storageEnvironments": [
                {
                    "provider": {"_id": "2"},
                    "version": "9",
                    "credentials": {
                        "endPoint": migration_config['ontap_config']['endpoint'],
                        "loginId": migration_config['ontap_config']['username'],
                        "password": migration_config['ontap_config']['password'],
                        "skipSSLValidation": migration_config['ontap_config']['skip_ontap_sll_validation']
                    }
                }
            ],
            "sddcEnvironments": [],
            "storageType": "ontap_nfs",
            "hypervisor": "vmware"
        }

        # Build payload for destination site (uses hyperv_config for virtualization)
        destination_payload = {
            "name": migration_config['destination_site_name'],
            "connectorId": "connector_id",
            "sitePurpose": {"_id": "2"},
            "location": {"_id": "1"},
            "virtualizationEnvironments": [
                {
                    "provider": {"_id": "3"},
                    "version": "7",
                    "credentials": {
                        "endPoint": migration_config['hyperv_config']['endpoint'],
                        "loginId": migration_config['hyperv_config']['username'],
                        "password": migration_config['hyperv_config']['password'],
                        "endPointType": migration_config['hyperv_config']['endpoint_type']
                    }
                }
            ],
            "storageEnvironments": [
                {
                    "provider": {"_id": "2"},
                    "version": "9",
                    "credentials": {
                        "endPoint": migration_config['ontap_config']['endpoint'],
                        "loginId": migration_config['ontap_config']['username'],
                        "password": migration_config['ontap_config']['password'],
                        "skipSSLValidation": migration_config['ontap_config']['skip_ontap_sll_validation']
                    }
                }
            ],
            "sddcEnvironments": [],
            "storageType": "ontap_nfs",
            "hypervisor": "hyperv"
        }

        # Choose payload based on site_type
        payload = source_payload if site_type == 'source' else destination_payload if site_type == "destination" else None

        response_status_code, response_txt, json_dic = self.api.api_request(
            method='POST', 
            url=url,
            json=payload,
            headers=headers,
            json_key=['_id']
        )
        if response_status_code == 200 and json_dic.get('_id') is not None:
            logger.info(f"{site_type.capitalize()} site id created is {json_dic['_id']}, Response code is {response_status_code}")
            return json_dic['_id']
        else:
            logger.error(f"{site_type.capitalize()} site id not created, Response code is {response_status_code}, response message is {response_txt}")
            return False

    def get_site(self, session_id, logger):
        url = self.uri + ":3700/api/setup/site"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            site_count = json_val['fetchedCount']
            site_list = json_val['list']
            logger.info(f"Source site id created, Response code is {response_status_code}")
            return site_count, site_list
        else:
            logger.error(f"Source site id not created, Response code is {response_status_code}, response message is {response_txt}")
            return None

    def get_vmware_site_details_by_id(self, session_id, site_id, logger):
        if site_id:
            logger.info(f"Getting vmware site details using GET /api/setup/site API for {site_id}")
            site_count, site_list = self.get_site(session_id, logger)
            if not site_list:
                return False
            for site in site_list:
                if site['hypervisor'] == 'vmware' and site['_id'] == site_id:
                    logger.info(f"VMware source site details created are {site}")
                    return site
            logger.error(f"VMware source site details not created for {site_id}")
            return False
        else:
            logger.error(f"VMware source site details not created as site_id is empty, please check previous logs")
            return False

    def get_hyperv_site_details_by_id(self, session_id, site_id, logger):
        logger.info(f"Getting hyper-v site details using GET /api/setup/site API for {site_id}")
        site_count, site_list = self.get_site(session_id, logger)
        if not site_list:
            return False
        for site in site_list:
            if site['hypervisor'] == 'hyperv' and site['_id'] == site_id:
                logger.info(f"Hyper-V destination site details created are {site}")
                return site
        logger.error(f"Hyper-V destination site details not created for {site_id}")
        return False

    def delete_site(self, session_id, site_id, logger):
        url = f"{self.uri}:3700/api/setup/site/{site_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt = self.api.api_request(method='DELETE', url=url, headers=headers)
        if response_status_code == 200:
            logger.info(f"Source site {site_id} is deleted using DELETE "
                        f"/api/setup/site/<site_id> API")
            return not self.get_vmware_site_details_by_id(session_id, site_id, logger)
        logger.error(f"Source site {site_id} is not deleted using DELETE "
                     f"/api/setup/site/<site_id> API")
        return False

    def get_site_using_site_id(self, session_id, site_id, logger):
        logger.info(f"Getting vmware site virtual environment details using GET /api/setup/site/<site-id> API for {site_id}")
        url = f"{self.uri}:3700/api/setup/site/{site_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            logger.info(f"VMware site virtual environment details created are {json_val} for site id {site_id}")
            return json_val
        else:
            logger.error(f"VMware site virtual environment details not created for site id {site_id}")
            return None

    def get_vmware_virtual_details_using_site_id(self, session_id, site_id, logger):
        logger.info(f"Getting vmware site virtual environment details using GET /api/setup/site API for {site_id}")
        site_list = self.get_site_using_site_id(session_id, site_id, logger)
        if not site_list:
            logger.error(f"VMware site virtual environment details not created for site id {site_id}")
            return False
        else:
            logger.info(f"VMware site virtual environment details created for site id {site_id}")
            return site_list['virtualizationEnvironments'][0]['_id']

    def get_unprotected_vm_using_site_id(self, session_id, site_id, virt_id, logger):
        logger.info(f"Getting unprotected vm details by site id using GET /api/setup/site API for {site_id}")
        url = f"{self.uri}:3700/api/setup/vm/unprotected?siteId={site_id}&virtEnvId={virt_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            site_count = json_val['fetchedCount']
            site_list = json_val['list']
            logger.info(f"Unprotected vm details created for site id {site_id} and virtual environment id {virt_id} is {json_val}")
            # find_sibling_and_child_value(site_list,vm_name)
            return site_count, site_list
        else:
            logger.error(f"Unprotected vm details does not contain details related to site id {site_id} and virtual environment id {virt_id}")
            return None

    def wait_for_site_discovery(self, session_id, site_id, logger, timeout=20, site_type='source'):
        logger.info(f"Waiting for site discovery to complete for site id {site_id}")
        expected_status = 4
        for _ in range(timeout + 1):
            site_list = self.get_vmware_site_details_by_id(session_id, site_id, logger) if site_type == "source" else self.get_hyperv_site_details_by_id(session_id, site_id, logger)
            for discovery_status in site_list["discoveryStatuses"]:
                if discovery_status["status"] == expected_status:
                    logger.info(f"Status is {expected_status}. Exiting wait loop for target discovery.")
                    return True
            time.sleep(1)
        logger.error(f"Status is {expected_status} even after {timeout} secs. Discovery is not completed.")
        return False

    def get_resources_by_site_virtenv_id(self, session_id, site_id, virtenv_id, logger):
        logger.info(f"Getting resource details by site and virtual env id using GET /api/setup/site API for {site_id} and {virtenv_id}")
        url = self.uri + f":3700/api/setup/site/{site_id}/virtEnv/{virtenv_id}/resource"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            resource_count = json_val['fetchedCount']
            resource_list = json_val['list']
            logger.info(f"Resource details for site id {site_id} and virtual environment id {virtenv_id} are {json_val}")
            return resource_count, resource_list
        else:
            logger.error(f"Resource details for site id {site_id} and virtual environment id {virtenv_id} are not found")
            return None

    def get_resource_details_by_name(self, session_id, resource_name, site_id, virtenv_id, logger):
        logger.info(f"Getting resource details by name using GET /api/setup/site API for {site_id} and {virtenv_id}")
        resource_count, resource_list = self.get_resources_by_site_virtenv_id(session_id, site_id, virtenv_id, logger)
        if not resource_list:
            logger.error(f"Resource details for {resource_name} are not found")
            return False
        for resource in resource_list:
            if resource['name'] == resource_name:
                logger.info(f"Resource details for {resource_name} are {resource}")
                return resource

    def get_site_details_by_name(self, session_id, site_name, logger):
        logger.info(f"Getting site details by name using GET /api/setup/site API for {site_name}")
        site_count, site_list = self.get_site(session_id, logger)
        if not site_list:
            logger.error(f"Site details for {site_name} are not found")
            return False
        for site in site_list:
            if site['name'] == site_name:
                logger.info(f"Site details for {site_name} are {site}")
                return site


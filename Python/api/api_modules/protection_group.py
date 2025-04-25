import json

from api_wrapper import APIWrapper
from api.api_modules.site import SiteAPI
from utils.parse_json import convert_to_defaultdict
from utils.parse_json import find_sibling_and_child_value

class ProtectionGroupAPI:

    def __init__(self, logger, shift_server_ip):
        self.uri = shift_server_ip
        self.api = APIWrapper(logger)

    def create_resource_group(self, session_id, migration_config, source_site_name, dest_site_name, logger):
        logger.info(f"Creating resource group(s) using GET /api/setup/protectiongroup API for source site {source_site_name} and destination site {dest_site_name}")

        site_api = SiteAPI(logger, self.uri)

        source_site_details = site_api.get_site_details_by_name(session_id, source_site_name, logger)
        dest_site_details = site_api.get_site_details_by_name(session_id, dest_site_name, logger)

        if not source_site_details or not dest_site_details:
            logger.error("Error retrieving site details for source or destination.")
            return False

        source_site_id = source_site_details.get("_id")
        dest_site_id = dest_site_details.get("_id")
        
        
        sourcer_vir_env = site_api.get_vmware_virtual_details_using_site_id(session_id, source_site_id, logger)
        dest_vir_env = site_api.get_vmware_virtual_details_using_site_id(session_id, dest_site_id,
                                                                         logger)
        site_count, vm_list = site_api.get_unprotected_vm_using_site_id(session_id, source_site_id, sourcer_vir_env, logger)

        vm_details_json = migration_config.get("vm_details")
        if vm_details_json is None:
            exit(1)

        # Group the VM entries by their resource_group_name.
        groups = {}
        for vm_entry in vm_details_json:
            resource_group_name = vm_entry.get("resource_group_name")
            if not resource_group_name:
                logger.error("Missing resource_group_name in vm_details entry.")
                exit(1)
            groups.setdefault(resource_group_name, []).append(vm_entry)

        resource_group_ids = []

        # Iterate over each group as grouped by resource_group_name.
        for resource_group_name, vm_details_group in groups.items():
            vms = []
            boot_order_list = []
            boot_delay_list = []
            datastore_mapping_list = []

            for vm_entry in vm_details_group:
                vm_name = vm_entry.get("name")
                order_val = vm_entry.get("boot_order")
                delay_val = vm_entry.get("delay")
                datastore_name = vm_entry.get("datastore_name")
                qtree_name = vm_entry.get("qtree_name")

                # Find matching VM id from the vm_list.
                vm_id = str(find_sibling_and_child_value(vm_list, "name", vm_name, "_id"))

                vms.append({"_id": vm_id})
                boot_order_list.append({"vm": {"_id": vm_id}, "order": int(order_val)})
                boot_delay_list.append({"vm": {"_id": vm_id}, "delaySecs": int(delay_val)})

                datastore_mapping_list.append({
                    "vm": {"_id": vm_id},
                    "datastoreName": datastore_name,
                    "qtreeName": qtree_name,
                    "volumeName": datastore_name
                })

            url = f"{self.uri}:3700/api/setup/protectionGroup"
            headers = {
                'Content-Type': 'application/json',
                'netapp-sie-sessionid': session_id
            }

            payload = {
                "name": resource_group_name,
                "sourceSite": {
                    "_id": source_site_id
                },
                "sourceVirtEnv": {
                    "_id": sourcer_vir_env
                },
                "vms": vms,
                "bootOrder": {
                    "vms": boot_order_list
                },
                "bootDelay": boot_delay_list,
                "scripts": [],
                "replicationPlan": {
                    "targetSite": {
                        "_id": dest_site_id
                    },
                    "targetVirtEnv": {
                        "_id": dest_vir_env
                    },
                    "datastoreQtreeMapping": datastore_mapping_list,
                    "snapshotType": migration_config['migration_mode'],
                    "frequencyMins": "30",
                    "retryCount": 3,
                    "numSnapshotsToRetain": 2
                },
                "migrationMode": migration_config['migration_mode']
            }

            response_status_code, response_txt, json_dic = self.api.api_request(
                method='POST',
                url=url,
                json=payload,
                headers=headers,
                json_key=['session']
            )

            if response_status_code == 200:
                resource_group_id = json.loads(response_txt)['_id']
                logger.info(f"Resource group : {resource_group_name} with id: {resource_group_id} is created using POST /api/setup/protectionGroup API, Response code is {response_status_code}")
                resource_group_ids.append(resource_group_id)
            else:
                logger.error(f"Resource group : {resource_group_name} is not created using POST /api/setup/protectionGroup API, Response code is {response_status_code} and Response message is {response_txt}")

        return resource_group_ids

    def delete_resource_group(self, session_id, resource_group_id, logger):
        logger.info(f"Deleting resource group using GET /api/setup/protectiongroup API for {resource_group_id}")
        url = f"{self.uri}:3700/api/setup/protectiongroup/{resource_group_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt = self.api.api_request(method='DELETE', url=url, headers=headers)
        if response_status_code == 200:
            logger.info(f"Resource group {resource_group_id} is deleted using DELETE "
                        f"/api/setup/protectiongroup/<resource_group_id> API, Response code is {response_status_code}")
            return not self.get_resource_group_details_from_list(session_id, resource_group_id, logger)
        else:
            logger.error(f"Resource group {resource_group_id} is not deleted using DELETE "
                        f"/api/setup/protectiongroup/<resource_group_id> API, Response code is {response_status_code} and Response message is {response_txt}")
            return False

    def get_resource_group_details_by_id(self, session_id, resource_group_id, logger):
        logger.info(f"Getting resource group details using GET /api/setup/protectiongroup/ API for {resource_group_id}")
        url = f"{self.uri}:3700/api/setup/protectiongroup/{resource_group_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)

        if not response_txt:
            logger.error(f"Resource group details for {resource_group_id} not found: ")
            return False
        else:
            logger.info(f"Resource group details for {resource_group_id} are {response_txt} and response code is {response_status_code}")
            return response_txt

    def get_all_resource_group(self, session_id, logger):
        logger.info(f"Getting all resource group using GET /api/setup/protectiongroup API")
        url = self.uri + ":3700/api/setup/protectiongroup"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            resource_group_count = json_val['fetchedCount']
            resource_group_list = json_val['list']
            logger.info(f"Resource group details are {json_val}, Response code is {response_status_code}")
            return resource_group_count, resource_group_list
        else:
            logger.error(f"Resource group details not found: Response code is {response_status_code}, response message is {response_txt}")
            return None

    def get_resource_group_details_from_list(self, session_id, resource_group_id, logger):
        logger.info(f"Getting vmware site details using GET /api/setup/protectiongroup API for {resource_group_id}")
        resource_group_count, resource_group_list = self.get_all_resource_group(session_id, logger)
        if not resource_group_list:
            return False
        for resource_group in resource_group_list:
            if resource_group['_id'] == resource_group_id:
                logger.info(f"Resource group details created are {resource_group}")
                return resource_group
        logger.error(f"Resource group details for {resource_group_id} not found")
        return False

    def get_unprotected_vm_list(self, session_id, logger):
        url = self.uri + ":3700/api/setup/vm/unprotected?siteId=9437fe7b-c3c1-4735-b73b-55d6046ec8c1&virtEnvId=c7920a32-d9ed-4c75-8c1e-81604ff9efbf"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            vm_count = json_val['fetchedCount']
            vm_list = json_val['list']
            logger.info(f"Unprotected VM details are {json_val}")
            return vm_count, vm_list
        else:
            logger.error("Unprotected VM details not found")
            return None

    def get_resource_group_by_site_virtenv_id(self, session_id, site_id, virtenv_id, logger):
        logger.info(f"Getting resource group by site id and virtenv id using GET /api/setup/protectionGroup?siteId={site_id}&virtEnvId={virtenv_id} API for {site_id}")
        url = self.uri + f":3700/api/setup/protectionGroup?siteId={site_id}&virtEnvId={virtenv_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            vm_count = json_val['fetchedCount']
            vm_list = json_val['list']
            logger.info(f"Resource group details are {json_val} for resource group by site and virtual env id, Response code is {response_status_code}")
            return vm_count, vm_list
        else:
            logger.error(f"Resource group details not found for resource group by site and virtual env id, Response code is {response_status_code}, response message is {response_txt}")
            return None

    def get_resource_group_details_by_name(self, session_id, resource_group_name, logger):
        logger.info(f"Getting resource group details using GET /api/setup/protectionGroup API for {resource_group_name}")
        site_count, site_list = self.get_all_resource_group(session_id, logger)
        if not site_list:
            logger.error("No resource groups available.")
            return []

        matching_groups = []
        for pg in site_list:
            if pg.get("name") == resource_group_name:
                matching_groups.append(pg)

        if matching_groups:
            logger.info(f"Found resource group details for {resource_group_name}: {matching_groups}")
            return matching_groups
        else:
            logger.error(f"Resource group details for {resource_group_name} not found")
            return []
    
    def get_resource_group_id_by_name(self, session_id, resource_group_name, logger):
        logger.info(f"Getting resource group details using GET /api/setup/protectionGroup API for {resource_group_name}")
        site_count, site_list = self.get_all_resource_group(session_id, logger)
        if not site_list:
            logger.error("No resource groups available.")
            return []

        matching_groups = []
        for pg in site_list:
            if pg.get("name") == resource_group_name:
                matching_groups.append(pg.get("_id"))

        if matching_groups:
            logger.info(f"Found resource group details for {resource_group_name}: {matching_groups}")
            return matching_groups
        else:
            logger.error(f"Resource group details for {resource_group_name} not found")
            return []

import json
import time

from api_wrapper import APIWrapper
from utils.parse_json import convert_to_defaultdict
from api.api_modules.protection_group import ProtectionGroupAPI
from api.api_modules.site import SiteAPI


class BluePrintAPI:
    def __init__(self, logger, shift_server_ip):
        self.uri = shift_server_ip
        self.api = APIWrapper(logger)

    def create_blueprint(self, session_id, migration_config, logger, workflow_type="clone_based_migration"):
        site_api = SiteAPI(logger, self.uri)
        resource_group_api = ProtectionGroupAPI(logger, self.uri)
        logger.info("Creating DRplan using POST /api/setup/drplan API for data")
        url = f"{self.uri}:3700/api/setup/drplan"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }

        source_site_id = site_api.get_site_details_by_name(session_id, migration_config["source_site_name"], logger)["_id"]
        source_virt_env_id = site_api.get_vmware_virtual_details_using_site_id(session_id, source_site_id, logger)
        target_site_id = site_api.get_site_details_by_name(session_id, migration_config["destination_site_name"], logger)["_id"]
        target_virt_env_id = site_api.get_vmware_virtual_details_using_site_id(session_id, target_site_id, logger)

        unique_rg_names = {
            vm_detail.get("resource_group_name")
            for vm_detail in migration_config.get("vm_details", [])
            if vm_detail.get("resource_group_name")
        }

        resource_group_list = []
        for rg_name in unique_rg_names:
            rg_details = resource_group_api.get_resource_group_details_by_name(session_id, rg_name, logger)
            if rg_details:
                resource_group_list.extend(rg_details)

        rg_list = [{"_id": rg["_id"]} for rg in resource_group_list]

        rg_to_boot_order = {}
        for vm_detail in migration_config.get("vm_details", []):
            rg_name = vm_detail.get("resource_group_name")
            if rg_name and rg_name not in rg_to_boot_order:
                rg_to_boot_order[rg_name] = vm_detail.get("boot_order", 0)

        boot_list = []
        for rg in resource_group_list:
            order = rg_to_boot_order.get(rg.get("name"), migration_config["vm_details"][0].get("boot_order", 0))
            boot_list.append({"protectionGroup": {"_id": rg["_id"]}, "order": order})

        vm_boot_order_map = {}
        for vm_detail in migration_config.get("vm_details", []):
            vm_boot_order_map[vm_detail["name"]] = vm_detail.get("boot_order", 0)

        vms_payload_list = []
        for rg in resource_group_list:
            for vm in rg.get("vms", []):
                vm_name = vm.get("name", "")
                order = vm_boot_order_map.get(vm_name, 0)
                vms_payload_list.append({"vm": {"_id": vm["_id"]}, "order": order})

        vm_name_to_id = {}
        for rg in resource_group_list:
            for vm in rg.get("vms", []):
                if "name" in vm and "_id" in vm:
                    vm_name_to_id[vm["name"]] = vm["_id"]

        for vm_detail in migration_config.get("vm_details", []):
            if "_id" not in vm_detail:
                vm_name = vm_detail.get("name")
                if vm_name in vm_name_to_id:
                    vm_detail["_id"] = vm_name_to_id[vm_name]
                else:
                    logger.error(f"VM id not found for VM name {vm_name}. Please check that the resource group was created correctly.")
                    exit(1)

        source_resource_list = [resource for resource in site_api.get_resources_by_site_virtenv_id(session_id, source_site_id, source_virt_env_id, logger)[1] if "type" not in resource.get("providerParams", {}) or resource["providerParams"]["type"] != "STANDARD_PORTGROUP"]
        target_resource_list = site_api.get_resources_by_site_virtenv_id(session_id, target_site_id, target_virt_env_id, logger)[1]
        combined_resource_list = source_resource_list + target_resource_list

        def parse_test_data(key):
            return [{"key": k, "value": v} for k, v in migration_config.get(key, {}).items()]

        if workflow_type == "clone_based_migration":
            vm_settings_list = []
            for vm_detail in migration_config.get("vm_details", []):
                vm_network_data = vm_detail.get("networkDetails", [])

                vm_cpu_data = vm_detail.get("numCPUs")
                vm_mem_data = vm_detail.get("memoryMB")
                vm_ip_data = vm_detail.get("ip")
                vm_gen_data = vm_detail.get("vmGeneration")
                vm_secure_boot_data = vm_detail.get("isSecureBootEnable")
                vm_retain_mac_data = vm_detail.get("retainMacAddress")
                vm_ip_alloc_data = vm_detail.get("ipAllocType")
                vm_sv_acc_flag_data = vm_detail.get("serviceAccountOverrideFlag")
                vm_sv_acc_creds_data = vm_detail.get("serviceAccount", {})
                power_on_alloc_data = vm_detail.get("powerOnFlag")

                network_list = [
                    {
                        "uuid": resource["uuid"],
                        "name": resource["name"],
                        "portGroupType": resource["providerParams"]["type"]
                    }
                    for resource in combined_resource_list
                    if resource["name"] in vm_network_data and resource["providerParams"]["type"] == "DISTRIBUTED_PORTGROUP"
                ]

                vm_setting = {
                    "vm": {"_id": vm_detail["_id"]},
                    "name": vm_detail["name"],
                    "numCPUs": vm_cpu_data,
                    "memoryMB": vm_mem_data,
                    "ip": vm_ip_data,
                    "vmGeneration": vm_gen_data,
                    "nicIp": [],
                    "isSecureBootEnable": vm_secure_boot_data,
                    "retainMacAddress": vm_retain_mac_data,
                    "networkDetails": network_list,
                    "networkName": vm_network_data,
                    "order": vm_detail.get("boot_order", 0),
                    "ipAllocType": vm_ip_alloc_data,
                    "powerOnFlag": power_on_alloc_data
                }

                if vm_sv_acc_flag_data:
                    vm_setting["serviceAccountOverrideFlag"] = vm_sv_acc_flag_data
                    vm_setting["serviceAccount"] = {
                        "loginId": vm_sv_acc_creds_data.get("loginId", ""),
                        "password": vm_sv_acc_creds_data.get("password", "")
                    }

                vm_settings_list.append(vm_setting)

            mappings_raw = migration_config.get("mappings", {})
            mappings = [
                {
                    "sourceResource": {"_id": next(item["_id"] for item in combined_resource_list if item["name"] == source)},
                    "targetResource": {"_id": next(item["_id"] for item in combined_resource_list if item["name"] == target)}
                }
                for source, target in mappings_raw.items()
            ]
        else:
            vm_settings_list = []
            mappings = []

        blueprint_payload = {
            "name": migration_config["blueprint_name"],
            "sourceSite": {"_id": source_site_id},
            "sourceVirtEnv": {"_id": source_virt_env_id},
            "targetSite": {"_id": target_site_id},
            "targetVirtEnv": {"_id": target_virt_env_id},
            "rpoSeconds": 0,
            "rtoSeconds": 0,
            "protectionGroups": rg_list,
            "bootOrder": {
                "protectionGroups": boot_list,
                "vms": vms_payload_list if workflow_type == "clone_based_migration" else []
            },
            "vmSettings": vm_settings_list,
            "mappings": mappings if workflow_type == "clone_based_migration" else [],
            "ipConfig": {"type": migration_config["ip_type"], "targetNetworks": []},
            "serviceAccounts": [
                {"os": "windows", "loginId": migration_config["windows_loginId"], "password": migration_config["windows_password"]},
                {"os": "linux", "loginId": migration_config["linux_loginId"], "password": migration_config["linux_password"]}
            ]
        }

        response_status_code, response_txt, json_dic = self.api.api_request(
            method='POST', url=url, json=blueprint_payload, headers=headers, json_key=['_id']
        )
        if response_status_code == 200 and json_dic.get('_id') is not None:
            logger.info(f"Blueprint id created is {json_dic['_id']}, Response code is {response_status_code}")
            return json_dic['_id']
        else:
            logger.error(f"Failed to create blueprint, Response code is {response_status_code}, response message is {response_txt}")
            return False

    def run_compliance_check_on_blueprint(self, session_id, blueprint_id, logger):
        logger.info(f"Executing compliance check for blueprint id {blueprint_id}")
        url = self.uri + f":3700/api/setup/compliance/drplan/{blueprint_id}/checkrequest?async=true"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id,
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='POST', url=url, headers=headers, timeout=300)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            complaince_status = json_val['status']
            compliance_task_id = json_val['taskId']
            logger.info(f"Compliance check was successfully executed for blueprint {blueprint_id} with task id {json_val['taskId']}")
            return complaince_status, compliance_task_id
        else:
            logger.error(f"Failed to execute compliance check for blueprint {blueprint_id}, Response code is {response_status_code}, response message is {response_txt}")
            return False

    def get_compliance_check_status_on_blueprint(self, session_id, compliance_task_id, logger):
        logger.info(f"Executing get compliance /api/setup/compliance/drplan/{compliance_task_id}/checkrequest?taskId={compliance_task_id} API")
        url = self.uri + f":3700/api/setup/compliance/drplan/{compliance_task_id}/checkrequest?taskId={compliance_task_id}"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='POST', url=url, headers=headers, timeout=300)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            complaince_status = json_val['status']
            compliance_result = json_val['result']
            logger.info(f"Compliance check was successfully executed for complaince id {compliance_task_id} with result {compliance_result}, Response code is {response_status_code}")
            return complaince_status, compliance_result
        else:
            logger.error(f"Failed to get /api/setup/compliance/drplan/{compliance_task_id}/checkrequest?taskId={compliance_task_id} API check for complaince id {compliance_task_id}, Response code is {response_status_code}, response message is {response_txt}")
            return False

    def verify_compliance_check_status(self, session_id, compliance_task_id, logger, timeout=12):
        compliance_result = None
        for _ in range(timeout):
            complaince_status, compliance_result = self.get_compliance_check_status_on_blueprint(session_id, compliance_task_id, logger)
            if complaince_status == "succeeded":
                logger.info(f"Compliance check status is {complaince_status}")
                return complaince_status, compliance_result
            else:
                logger.info(f"Compliance check status is {complaince_status}, Retrying after 5 sec")
                time.sleep(5)
        logger.error(f"Timeout occurred while verifying compliance check status after {timeout} secs")
        return False, compliance_result

    def validate_compliance_for_workflows(self, compliance_data, logger, workflow_type="clone_based_migration"):
        logger.info(f"Validating compliance data {compliance_data }for workflow type {workflow_type}")
        source_flag = False
        target_flag = False
        if len(compliance_data) > 0 and compliance_data[0]["sourceCheckResult"] and compliance_data[0]["targetCheckResult"]:
            source_check_list = compliance_data[0]["sourceCheckResult"]
            target_check_list = compliance_data[0]["targetCheckResult"]
            if len(source_check_list) == 10:
                source_flag = False
            if workflow_type == "clone_based_migration":
                if len(target_check_list) == 4:
                    target_flag = True
            elif workflow_type == "clone_based_conversion":
                if len(target_check_list) == 1:
                    target_flag = True
            logger.info(f"Compliance check for source is {source_flag} and target is {target_flag}")
        else:
            logger.error(f"Compliance data is empty --> {compliance_data}")
        return source_flag, target_flag

    def execute_blueprint(self, session_id, logger, blueprint_id, execution_type="clone_based_migration"):
        logger.info(f"Executing blueprint id {blueprint_id} with mode {execution_type} using GET /api/recovery/drPlan/{blueprint_id}/{execution_type}/execution")
        type = "migrate" if execution_type == "clone_based_migration" else "convert"
        url = self.uri + f":3704/api/recovery/drPlan/{blueprint_id}/{type}/execution"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        payload = {
            "serviceAccounts": {
                "common": {
                    "loginId": None,
                    "password": None
                },
                "vms": []
            }
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='POST', url=url, json=payload, headers=headers, json_key=['_id'])
        if response_status_code == 200:
            logger.info(f"Blueprint {blueprint_id} was executed with mode {execution_type} successfully with id {json_dic['_id']}, Response code is {response_status_code}")
            return json_dic['_id']
        else:
            logger.error(f"Failed to execute blueprint {blueprint_id} with mode {execution_type}, Response code is {response_status_code}, response message is {response_txt}")
            return False

    def get_blueprint_status(self, session_id, logger):
        logger.info(f"Retrieving blueprint status using GET /api/recovery/drplan/status")
        url = self.uri + ":3704/api/recovery/drplan/status"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code = None
        response_txt = None
        try:
            response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
            if response_status_code == 200:
                json_val = json.loads(response_txt)
                logger.info(f"Response code for Blueprint status is {response_status_code}")
                return json_val
            else:
                return None
        except Exception as e:
            logger.warning(f"Error occurred while retrieving blueprint status using GET /api/recovery/drplan/status: {e}")
            return None

    def verify_blueprint_status(self, session_id, blueprint_id, logger, timeout=40):
        logger.info(f"Check blueprint status for id {blueprint_id} with timeout {timeout} seconds")
        for _ in range(timeout):
            blueprint_status = self.get_blueprint_status(session_id, logger)
            if not blueprint_status:
                continue
            for blueprint in blueprint_status:
                if blueprint["drPlan"]["_id"] == blueprint_id:
                    status = blueprint['drPlan']['recoveryStatus']
                    if "complete" in status or "error" in status:
                        logger.info(f"Blueprint status for blueprint id {blueprint_id} is {status}")
                        return status
            logger.info(f"Verifying blueprint status for blueprint id {blueprint_id}: Current status is {status}")
            time.sleep(30)
        logger.error(f"Timeout occurred while verifying blueprint status for blueprint id {blueprint_id}")
        return False

    def get_blueprint(self, session_id, logger):
        logger.info(f"Retrieving blueprint using GET /api/setup/drplan")
        url = self.uri + ":3700/api/setup/drplan"
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
        if response_status_code == 200:
            json_val = json.loads(response_txt)
            blueprint_count = json_val['fetchedCount']
            blueprint_list = json_val['list']
            logger.info(f"Retrieved blueprint count is {blueprint_count} and list is {blueprint_list}, Response code is {response_status_code}")
            return blueprint_count, blueprint_list
        else:
            logger.error(f"Failed to retrieve blueprint, Response code is {response_status_code}, response message is {response_txt}")
            return None

    def get_blueprint_by_id(self, session_id, blueprint_id, logger):
        logger.info(f"Retrieving blueprint using GET /api/setup/drplan by id {blueprint_id}")
        blueprint_count, blueprint_list = self.get_blueprint(session_id, logger)
        for blueprint in blueprint_list:
            if blueprint["_id"] == blueprint_id:
                logger.info(f"Retrieved blueprint by id {blueprint_id} is {blueprint}")
                return blueprint
        logger.error(f"Retrieved blueprint by id {blueprint_id} is not found")
        return False
    
    def get_blueprint_id_by_name(self, session_id, blueprint_name, logger):
        logger.info(f"Retrieving blueprint using GET /api/setup/drplan by name {blueprint_name}")
        blueprint_count, blueprint_list = self.get_blueprint(session_id, logger)
        for blueprint in blueprint_list:
            if blueprint["name"] == blueprint_name:
                logger.info(f"Retrieved blueprint by name {blueprint_name} is {blueprint}")
                return blueprint["_id"]
        logger.error(f"Retrieval of blueprint id by name {blueprint_name} is not found")
        return False

    def wait_for_prepare_vm_execution(self, session_id, blueprint_id, logger, timeout=1000):
        logger.info(f"Waiting for prepare vm to complete for blueprint id {blueprint_id}")
        expected_status = 4
        failed_status = 5
        for _ in range(timeout + 1):
            blueprint_list = self.get_blueprint_status(session_id, logger)
            for prepare_vm_status in blueprint_list:
                if prepare_vm_status["drPlan"]['_id'] == blueprint_id:
                    if prepare_vm_status['lastExecution']['status'] == expected_status:
                        logger.info(f"Status is {expected_status}. Exiting wait after prepare vm completion.")
                        return True
                    if prepare_vm_status['lastExecution']['status'] == failed_status:
                        logger.info(f"Status is {failed_status}. Exiting wait after prepare vm failure.")
                        return False
            time.sleep(1)
        logger.error(f"****Status is {expected_status} even after {timeout} secs. Prepare vm is not completed.****")
        return False

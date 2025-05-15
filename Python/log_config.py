import os
import logging
from datetime import datetime

LOGS_FOLDER = "logs"
os.makedirs(LOGS_FOLDER, exist_ok=True)

def get_logger(module_name, folder, filename_prefix):
    os.makedirs(folder, exist_ok=True)

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    log_filename = os.path.join(folder, f"{filename_prefix}_{timestamp}.log")

    logger = logging.getLogger(module_name)
    logger.setLevel(logging.INFO)

    if not logger.handlers:
        file_handler = logging.FileHandler(log_filename)
        file_formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)

        console_handler = logging.StreamHandler()
        console_formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        console_handler.setFormatter(console_formatter)
        logger.addHandler(console_handler)

    return logger

def get_add_site_logger():
    add_site_folder = os.path.join(LOGS_FOLDER, "Add Site Execution Logs")
    return get_logger("AddSite", add_site_folder, "AddSite")

def get_add_resource_group_logger():
    add_resource_group_folder = os.path.join(LOGS_FOLDER, "Add Resource Group Execution Logs")
    return get_logger("AddResourceGroup", add_resource_group_folder, "AddResourceGroup")

def check_migration_status_logger():
    check_migration_status_folder = os.path.join(LOGS_FOLDER, "Check Migration Status Execution Logs")
    return get_logger("CheckMigrationStatus", check_migration_status_folder, "CheckMigrationStatus")

def create_blueprint_logger():
    create_blueprint_folder = os.path.join(LOGS_FOLDER, "Create Blueprint Execution Logs")
    return get_logger("CreateBlueprint", create_blueprint_folder, "CreateBlueprint")

def check_prepare_vm_status_logger():
    prepare_vm_folder = os.path.join(LOGS_FOLDER, "Check Prepare VM Status Execution Logs")
    return get_logger("CheckMigrationStatus", prepare_vm_folder, "CheckMigrationStatus")

def run_compliance_check_logger():
    run_compliance_check_folder = os.path.join(LOGS_FOLDER, "Run Compliance Execution Logs")
    return get_logger("RunCompliance", run_compliance_check_folder, "RunCompliance")

def shift_api_automation_logger():
    shift_api_automation_folder = os.path.join(LOGS_FOLDER, "Shift Api Automation Execution Logs")
    return get_logger("ShiftApiAutomation", shift_api_automation_folder, "ShiftApiAutomation")

def trigger_migration_logger():
    trigger_migration_folder = os.path.join(LOGS_FOLDER, "Trigger Migration Execution Logs")
    return get_logger("TriggerMigration", trigger_migration_folder, "TriggerMigration")

def initiate_prepare_vm_logger():
    initiate_prepare_vm_folder = os.path.join(LOGS_FOLDER, "Initiate PrepareVM Execution Logs")
    return get_logger("InitiatePrepareVM", initiate_prepare_vm_folder, "InitiatePrepareVM")

def get_site_logger():
    get_site_folder = os.path.join(LOGS_FOLDER, "Get Site Execution Logs")
    return get_logger("GetSite", get_site_folder, "GetSite")

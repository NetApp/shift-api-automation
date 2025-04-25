import logging
import os
from envyaml import EnvYAML

source_dir = os.path.dirname(os.path.abspath(__file__))

logger = logging.getLogger(__name__)

try:
    cfg = EnvYAML(source_dir + "/Config.yml")

    class add_site_config():
        ifile = source_dir + cfg["add_site"]["ifile"]

    class add_resource_group_config():
        ifile = source_dir + cfg["add_resource_group"]["ifile"]
  
    class check_migration_status_config():
        ifile = source_dir + cfg["check_migration_status"]["ifile"]
        
    class check_prepare_vm_status_config():
        ifile = source_dir + cfg["check_prepare_vm_status"]["ifile"]
        
    class create_blueprint_config():
        ifile = source_dir + cfg["create_blueprint"]["ifile"]
        
    class run_compliance_check_config():
        ifile = source_dir + cfg["run_compliance_check"]["ifile"]
        
    class shift_api_automation_config():
        ifile = source_dir + cfg["shift_api_automation"]["ifile"]
        
    class trigger_migration_config():
        ifile = source_dir + cfg["trigger_migration"]["ifile"] 

except Exception as e:
    logger.error("Exception {} occurred while parsing config file")

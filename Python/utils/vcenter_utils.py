import atexit
import ssl
import time

from pyVim import connect
from pyVmomi import vim


class VcenterUtils():

    def __init__(self, logger, migration_config):
        self.si = None
        self.content = None
        self.logger = logger
        self.MigrationConfig = migration_config

    def create_vm_connection(self):
        vcenter_server = self.MigrationConfig.get("shift_server_ip").replace("http://","")
        vcenter_user = self.MigrationConfig.get("vmware_config").get("username")
        vcenter_password = self.MigrationConfig.get("vmware_config").get("password")
        s = ssl.SSLContext(ssl.PROTOCOL_TLS)
        s.verify_mode = ssl.CERT_NONE
        try:
            self.si = connect.SmartConnect(host=vcenter_server, user=vcenter_user, pwd=vcenter_password, sslContext=s)
            atexit.register(self.disconnect)
            self.content = self.si.RetrieveContent()
            self.logger.info(f"Connected to vcenter successfully.")
        except Exception as e:
            self.logger.info(f"Failed to connect to vCenter: {e}")

    def disconnect(self):
        if self.si:
            try:
                connect.Disconnect(self.si)
            except Exception as e:
                self.logger.info(f"Failed to disconnect from vCenter: {e}")

    def get_vm_by_name(self, content, vm_name):
        obj_view = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
        vm_list = obj_view.view
        obj_view.Destroy()
        for vm in vm_list:
            if vm.name == vm_name:
                return vm
        return None

    def wait_for_power_on(self, vm_name_list, timeout=15):
        for vm_name in vm_name_list:
            vm = self.get_vm_by_name(self.content, vm_name)
            count = 0
            while vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOn and count < timeout:
                self.logger(f"VM {vm_name} is still Powered Off, Please power it On to proceed")
                time.sleep(10)
                self.refresh_vm_data(vm)
                count+=1
            self.wait_for_ip(vm)

    def wait_for_power_off(self, vm_name_list, timeout=15):
        for vm_name in vm_name_list:
            vm = self.get_vm_by_name(self.content, vm_name)
            count = 0
            while vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOff and count < timeout:
                self.logger(f"VM {vm_name} is still Powered Off, Please power it Off to proceed")
                time.sleep(10)
                self.refresh_vm_data(vm)
                count+=1
            self.wait_for_ip(vm)

    def refresh_vm_data(self, vm):
        spec = vim.vm.ConfigSpec()
        task = vm.ReconfigVM_Task(spec)
        task_info = task.info
        while task_info.state == vim.TaskInfo.State.running:
            task_info = task.info
        if task_info.state == vim.TaskInfo.State.success:
            self.logger.info("VM data refreshed successfully.")
        else:
            self.logger.info(f"Failed to refresh VM data: {task_info.error}")

    def wait_for_ip(self, vm, timeout=60):
        for _ in range(timeout):
            for nic in vm.guest.net:
                for ip in nic.ipAddress:
                    if ip:
                        self.logger.info(f"VM {vm.name} is accessible at IP {ip}")
                        return True
            time.sleep(10)
        self.logger.info(f"Timed out waiting for VM {vm.name} to become accessible")
        return False

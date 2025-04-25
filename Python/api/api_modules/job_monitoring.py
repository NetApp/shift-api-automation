import json

from api_wrapper import APIWrapper


class JobMonitoring:

    def __init__(self, logger, shift_server_ip):
        self.uri = shift_server_ip
        self.api = APIWrapper(logger)

    def get_job_steps(self, session_id, execution_id, logger):
        try:
            logger.info("Retrieve job steps for execution id {}".format(execution_id))
            url = self.uri + f":3704/api/recovery/execution/{execution_id}/steps"
            headers = {
                'Content-Type': 'application/json',
                'netapp-sie-sessionid': session_id
            }
            response_status_code, response_txt, json_dic = self.api.api_request(method='GET', url=url, headers=headers)
            if response_status_code == 200:
                json_val = json.loads(response_txt)
                job_type = json_val['type']
                job_steps = json_val['steps']
                logger.info(f"Job steps successfully retrieved for execution id {execution_id}, Response code is {response_status_code}")
                logger.info(f"Job steps for execution id {execution_id} are {job_steps}")
                logger.info(f"Job type for execution id {execution_id} is {job_type}")
                return job_type, job_steps
            else:
                logger.error(f"Failed to retrieve job steps for execution id {execution_id}, Response code is {response_status_code}, response message is {response_txt}")
                return None
        except Exception as e:
            logger.error(f"Failed to get job steps for execution_id: {execution_id} with error {e}")


    def validate_job_steps_is_success(self, session_id, execution_id, logger):
        try:
            job_type, job_steps = self.get_job_steps(session_id, execution_id, logger)
            if job_steps:
                for step in job_steps:
                    if step['status'] != 4:
                        logger.error(f"Job step {step['description']} is not successful")
                        return False
                    elif step['status'] == 4:
                        logger.info(f"Job step {step['description']} is successful")
                return True
            else:
                logger.error(f"Failed to fetch Job steps for execution_id: {execution_id}")
                return False
        except Exception as e:
            logger.error(f"Failed to validate job steps for execution_id: {execution_id} with error {e}")

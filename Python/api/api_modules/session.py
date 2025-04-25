from api_wrapper import APIWrapper


class SessionAPI:

    def __init__(self, logger, shift_server_ip):
        self.uri = shift_server_ip
        self.api = APIWrapper(logger)

    def create_drom_session(self, login_id, password):
        url = self.uri + ":3698/api/tenant/session"
        payload = {
            "loginId": login_id,
            "password": password
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='POST', url=url, json=payload,
                                                                            json_key=['session'])
        if response_status_code == 200 and json_dic['session']['_id'] is not None:
            return json_dic['session']['_id']
        else:
            return False

    def end_drom_session(self, session_id):
        url = self.uri + ":3698/api/tenant/session/end"
        payload = {
                  "sessionId": "{}".format(session_id)
                }
        headers = {
            'Content-Type': 'application/json',
            'netapp-sie-sessionid': session_id
        }
        response_status_code, response_txt, json_dic = self.api.api_request(method='POST', url=url, json=payload,
                                                                            headers=headers)
        if response_status_code == 200:
            return True
        else:
            return False

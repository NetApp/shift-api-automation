import json

import requests

from utils.parse_json import parse_json

"""
Api Wrapper class to perform REST API calls using requests library
Author: Akshay Panambur
Date: 22/02/2022
"""


class APIWrapper:

    def __init__(self, logger):
        self.logger = logger

    def api_request(self, method='GET', **kwargs):
        try:
            if method.upper() == 'GET':
                return self._get_request(**kwargs)
            elif method.upper() == 'POST':
                return self._post_request(**kwargs)
            elif method.upper() == 'PUT':
                return self._put_request(**kwargs)
            elif method.upper() == 'DELETE':
                return self._delete_request(**kwargs)
        except Exception as e:
            self.logger.error("Error {} occurred while performing {} request ".format(e, method))

    def _get_request(self, **kwargs):
        response = None
        json_key = None
        json_dic = {}
        try:
            if self._validate_kwargs(**kwargs) and kwargs['url']:
                if 'json_key' in kwargs:
                    if kwargs['json_key']:
                        json_key = kwargs.pop('json_key')
            response = requests.get(**kwargs)
            if json_key is not None:
                if response.text:
                    for key in json_key:
                        json_val = parse_json(json.loads(response.text), key)
                        json_dic[key] = json_val
        except ConnectionResetError as f:
            self.logger.warning("Error {} occurred while performing get request for {}".format(f, kwargs))
        except Exception as e:
            self.logger.error("Error {} occurred while performing get request for {}".format(e, kwargs))
        return response.status_code, response.text, json_dic if len(json_dic) > 0 else None

    def _post_request(self, **kwargs):
        response = None
        json_key = None
        json_dic = {}
        try:
            if self._validate_kwargs(**kwargs):
                if kwargs['url']:
                    # if ('json' in kwargs) or ('data' in kwargs and kwargs['data']) or \
                    #         ('files' in kwargs and kwargs['files']):
                    if 'json_key' in kwargs:
                        if kwargs['json_key']:
                            json_key = kwargs.pop("json_key")
                    response = requests.post(**kwargs)
                    if json_key is not None:
                        if response.text:
                            for key in json_key:
                                json_val = parse_json(json.loads(response.text), key)
                                json_dic[key] = json_val
        except Exception as e:
            self.logger.error("Error {} occurred while performing post request for {}".format(e, kwargs))
        return response.status_code, response.text, json_dic

    def _put_request(self, **kwargs):
        response = None
        json_key = None
        json_dic = {}
        try:
            if self._validate_kwargs(**kwargs):
                if kwargs['url']:
                    if ('json' in kwargs and kwargs['json']) or ('data' in kwargs and kwargs['data']) or \
                            ('files' in kwargs and kwargs['files']):
                        if 'json_key' in kwargs:
                            if kwargs['json_key']:
                                json_key = kwargs.pop("json_key")
                        response = requests.put(**kwargs)
                        if json_key is not None:
                            if response.text:
                                for key in json_key:
                                    json_val = parse_json(json.loads(response.text), key)
                                    json_dic[key] = json_val
        except Exception as e:
            self.logger.error("Error {} occurred while performing put request for {}".format(e, kwargs))
        return response.status_code, response.text, json_dic

    def _delete_request(self, **kwargs):
        response = None
        try:
            if self._validate_kwargs(**kwargs) and kwargs['url']:
                response = requests.delete(**kwargs)
        except Exception as e:
            self.logger.error("Error {} occurred while performing delete request for {}".format(e, kwargs))
        return response.status_code, response.text

    def _validate_kwargs(self, **kwargs):
        standard_args = ["method", "url", "params", "data", "json", "headers", "cookies", "files", "auth", "timeout",
                         "allow_redirects", "proxies", "verify", "stream", "cert", "json_key"]
        flag = False
        try:
            non_standard_args = [key for key in kwargs.keys() if key not in standard_args]
            if not len(non_standard_args):
                flag = True
            else:
                self.logger.error("Keywords are invalid {}".format(non_standard_args))
                raise KeyError("Keywords are invalid: {}".format(non_standard_args))
        except Exception as e:
            self.logger.error("Error occurred while validating the keyword arguments {}".format(e))
        return flag

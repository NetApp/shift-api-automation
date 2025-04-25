import logging
from collections import defaultdict

logger = logging.getLogger(__name__)

"""
JSON parser function to parse json objects including multi level nested jsons
Author: Akshay Panambur
Date: 22/02/2022
"""


def parse_json(json_obj, key_name):
    value = None
    flag = False
    try:
        for item in json_obj:
            try:
                if item == key_name:
                    value = json_obj[item]
                    if value is not None:
                        return value
                elif isinstance(json_obj[item], dict):
                    if json_obj[item]:
                        value = parse_json(json_obj[item], key_name)
                        if value is not None:
                            return value
                elif isinstance(json_obj[item], list):
                    for comp in json_obj[item]:
                        if not flag:
                            for key, val in comp.items():
                                if not flag:
                                    if key == key_name:
                                        value = val
                                        flag = True
                                else:
                                    break
                        else:
                            break
            except Exception as e:
                logger.info("Skipping dic object")
                continue
    except Exception as f:
        logger.error("Error {} occurred while parsing json".format(f))
    return value


def convert_to_defaultdict(normal_dict, default_factory=lambda: None):
    default_dict = defaultdict(default_factory)
    for key, value in normal_dict.items():
        default_dict[key] = value
    return default_dict


def find_item_with_key_value(obj, search_key, search_value):
    if isinstance(obj, dict):
        if obj.get(search_key) == search_value:
            return obj
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                result = find_item_with_key_value(v, search_key, search_value)
                if result:
                    return result
    elif isinstance(obj, list):
        for item in obj:
            result = find_item_with_key_value(item, search_key, search_value)
            if result:
                return result
    return None


def find_sibling_and_child_value(json_data, search_key, search_value=None, expected_key_value=None):
    if search_value:
        if 'list' in json_data:
            search_data = json_data['list']
        else:
            search_data = json_data

        item = find_item_with_key_value(search_data, search_key, search_value)
    else:
        item = json_data

    if item and expected_key_value:
        key_path = expected_key_value.split('/')
        for key in key_path:
            item = next(find_key_value(item, key), None)
            if item is None:
                break
    return item


def find_item_with_key_value(obj, search_key, search_value):
    if isinstance(obj, dict):
        if obj.get(search_key) == search_value:
            return obj
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                result = find_item_with_key_value(v, search_key, search_value)
                if result:
                    return result
    elif isinstance(obj, list):
        for item in obj:
            result = find_item_with_key_value(item, search_key, search_value)
            if result:
                return result
    return None


def find_key_value(obj, key):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                yield v
            elif isinstance(v, (dict, list)):
                yield from find_key_value(v, key)
    elif isinstance(obj, list):
        for item in obj:
            yield from find_key_value(item, key)

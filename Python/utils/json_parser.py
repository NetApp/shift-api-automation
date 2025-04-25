import json

def json_parser(file_path):
    """
    Read and parse a JSON file.

    Args:
        file_path (str): The path to the JSON file.

    Returns:
        dict or list: Parsed JSON content.
    """
    with open(file_path, 'r') as file:
        data = json.load(file)
    return data
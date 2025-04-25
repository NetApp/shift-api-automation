from pymongo import MongoClient

class MongoDBClient:

    def __init__(self, logger, mongo_config):
        self.logger = logger
        self.uri = mongo_config.uri
        self.username = mongo_config.get("mongo_username")
        self.password = mongo_config.get("mongo_password")
        connection_str = f"mongodb://{self.username}:{self.password}@{self.uri}:27017"
        self.client = MongoClient(connection_str.replace("http://", ""))
        self.logger.info("MongoDB client initialized with provided credentials.")
    def delete_blueprint(self):
        db = self.client['draas_recovery']
        result = db.execution.delete_many({})
        self.logger.info(f"Deleted {result.deleted_count} documents from draas_recovery in mongodb")

    def delete_all_contents_in_draas_setup(self):
        db = self.client['draas_setup']
        collections = db.list_collection_names()
        delete_collection_list = ['volume', 'drplan', 'discovery', 'compliance', 'protectiongroup', 'resource', 'site', 'vm', 'replicationplan']
        for collection_name in collections:
            if collection_name in delete_collection_list:
                result = db[collection_name].delete_many({})
                self.logger.info(f"Deleted {result.deleted_count} documents from {collection_name} collection in draas setup mongodb")

    def close_db_client(self):
        if self.client:
            self.client.close()
            self.logger.info("Closed mongodb client")
        else:
            self.logger.info("MongoDB client is already closed")


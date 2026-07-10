import sys
from pymongo import MongoClient
import json

uri = "mongodb+srv://seyalteam_dmongob:X2f3IzZHGrVJDXo6@seyal.pkf6hae.mongodb.net/blackforest-payload?appName=Seyal"
client = MongoClient(uri, tlsAllowInvalidCertificates=True)
db = client["blackforest-payload"]

users_col = db["users"]
# Find users with roles other than waiter
other_users = list(users_col.find({"role": {"$ne": "waiter"}}))
print(f"Total non-waiter users: {len(other_users)}")
for u in other_users:
    print(f"- Name: {u.get('name')}, Role: {u.get('role')}, branch: {u.get('branch')}, lastLoginBranch: {u.get('lastLoginBranch')}")

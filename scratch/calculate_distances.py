import sys
from pymongo import MongoClient
from bson.objectid import ObjectId
import json
from math import radians, cos, sin, asin, sqrt

# Haversine distance helper
def haversine(lon1, lat1, lon2, lat2):
    lon1, lat1, lon2, lat2 = map(radians, [lon1, lat1, lon2, lat2])
    dlon = lon2 - lon1
    dlat = lat2 - lat1
    a = sin(dlat/2)**2 + cos(lat1) * cos(lat2) * sin(dlon/2)**2
    c = 2 * asin(sqrt(a))
    r = 6371000 # Radius of earth in meters
    return c * r

uri = "mongodb+srv://seyalteam_dmongob:X2f3IzZHGrVJDXo6@seyal.pkf6hae.mongodb.net/blackforest-payload?appName=Seyal"
client = MongoClient(uri, tlsAllowInvalidCertificates=True)
db = client["blackforest-payload"]

# User coordinates from today's attendance: 8.7843578, 78.1340681
user_lat = 8.7843578
user_lng = 78.1340681

# Fetch branch geo settings
geo_doc = db["globals"].find_one({"globalType": "branch-geo-settings"})
locations = geo_doc.get("locations", []) if geo_doc else []

print("DISTANCE FROM USER COORDINATES (8.7843578, 78.1340681) TO EACH BRANCH:")
for loc in locations:
    branch_id = loc.get("branch")
    branch = db["branches"].find_one({"_id": ObjectId(branch_id)})
    branch_name = branch.get("name") if branch else "Unknown"
    
    lat = loc.get("latitude")
    lng = loc.get("longitude")
    rad = loc.get("radius", 100)
    
    if lat is not None and lng is not None:
        dist = haversine(user_lng, user_lat, lng, lat)
        status = "INSIDE" if dist <= rad else "OUTSIDE"
        print(f"- {branch_name:<25} | Distance: {dist:<8.2f}m | Radius: {rad}m | Status: {status}")

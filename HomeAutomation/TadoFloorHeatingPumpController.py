import requests 
import json
import datetime
import time

data = {'grant_type':'password', 
        'scope':'home.user',
        'client_id':'tado-web-app', 
        'client_secret':'wZaRN7rpjn3FoNyF5IFuxg9uMzYJcvOoQ8QWiIqS3hfk6gLhVlG57j5YNoZL2Rtc', #see https://shkspr.mobi/blog/2019/02/tado-api-guide-updated-for-2019/ on how to get this client secret
        'username':'Test@test.com', #your tado login/email
        'password':'MyPassword' #your tado password
        }
hueBaseURL = "http://HUEBRIDGEIPHERE/api/USERNAMEHERE" #the IP and username of your HUE, see https://github.com/tigoe/hue-control for instructions on how to get the username
hueLightID = '6' #the ID of the Hue Power Plug in which you connected your floor heating pump, see https://github.com/tigoe/hue-control for instructions on how to get all ID's
tadoHomeId = '12345' #the home ID of your tado account, see https://shkspr.mobi/blog/2019/02/tado-api-guide-updated-for-2019/ on how to get the ID
tadoHeatingZoneId = '6' #the ID of the tado zone you are heating using a floor heating system, see https://shkspr.mobi/blog/2019/02/tado-api-guide-updated-for-2019/ on how to get the ID
r = requests.post('https://auth.tado.com/oauth/token', data = data) 
j = json.loads(r.text)
TOKEN = j["access_token"]
headers={'Authorization': "Bearer " + TOKEN}
r = requests.get('https://my.tado.com/api/v2/homes/'+tadoHomeId+'/zones/'+tadoHeatingZoneId+'/state', headers=headers)
j = json.loads(r.text)
desiredTemp = j["setting"]["temperature"]["celsius"]
currentTemp = j["sensorDataPoints"]["insideTemperature"]["celsius"]
currentPower = j["activityDataPoints"]["heatingPower"]["percentage"]
print("Status zone "+tadoHeatingZoneId+" : "+str(j["setting"]["power"]))
print("Heating power for zone "+tadoHeatingZoneId+" : "+str(currentPower)+"%")
print("Current temperature in zone "+tadoHeatingZoneId+" : "+str(currentTemp))
print("Target temp in zone "+tadoHeatingZoneId+" : "+str(desiredTemp))
r = requests.get(hueBaseURL+'/lights/'+hueLightID)
j = json.loads(r.text)
pumpState = j["state"]["on"]
print("Floor heating pump state: "+str(pumpState))
if currentPower > 0 and pumpState == False :
    print("PUMP SHOULD BE TURNED ON")
    r = requests.put(hueBaseURL+'/lights/'+hueLightID+'/state', data = '{"on":true}') 
    print(r.content)
    print("PUMP TURNED ON")
elif currentPower <= 0 and pumpState == True :
    print("PUMP SHOULD BE OFF")
    r = requests.put(hueBaseURL+'/lights/'+hueLightID+'/state', data = '{"on":false}')  
    print(r.content)
    print("PUMP TURNED OFF")



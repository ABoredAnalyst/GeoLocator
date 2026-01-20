* ~~Update manual investigation scripts to include the enhanced IP lookup functionality~~
* ~~Add comparison functionality between IP geolocation and machine geolocation to manual investigation scripts~~
* ~~Create readme for the ScheduledGeoLocator.ps1 script.~~
* ~~Update main readme with new functionalities and troubleshooting info~~
* Create readme for SuspiciousNetNeighbors.ps1
* IP-API has a limitation of 45 requests per minute before the requests is throttled (HTTP 429). This may cause an issue if this script were pushed out to hybrid environments where more than 45 machines are within a single office. Reference notes from [docs](https://ip-api.com/docs/api:json) for possible resolution:
  * The returned HTTP header X-Rl contains the number of requests remaining in the current rate limit window. X-Ttl contains the seconds until the limit is reset. Your implementation should always check the value of the X-Rl header, and if its is 0 you must not send any more requests for the duration of X-Ttl in seconds.
* Usage of IP-API in a commercial environment requires a pro license. Need to add disclaimer than this is a proof of concept and that the pro version of the API should be implemented into the script for commercial usage.
  * Create separate version of IP lookup allowing you to implement API key. Hardcoding API key isn't exactly best practice, but POC for the time being.

# SEAD APPLICATION

The SEAD application is run as a cluster of docker containers through docker-compose.

## Services
* PostgreSQL database
  * Main SEAD database
* PostgREST
  * Used for exposing database schema as REST API, which is utilized by the site reports.
* Viewstate server
  * NodeJS application handling viewstate saving & loading, using google accounts.
* MongoDB
  * Used by Viewstate server to store viewstates.
* Nginx httpd server
  * Used to serve the browser client.
* Sead query API
  * Service handling filtering logic.
* Redis
  * Caching of filter/result requests.
* Traefik
  * Not currently used


## Ports used:
* 5432 PostgreSQL - Internal
* 3000 PostgREST via Apache/Nginx - External
* 3001 PostgREST - Internal
* 80 HTTP - External
* 27017 MongoDB - Internal
* 8081 Viewstate server - External
* 8433 VIewstate server - External (SSL)
* 8089 Filter/Result API - External


## Installation
* `git clone https://github.com/humlab-sead/sead-docker-cluster`

## Setup
* WIP

### MongoDB
* chgrp -R docker mongodb/mounts
* chmod -R 0770 mongodb/mounts
  
### SEAD QUERY API


#Verify that necessary config files exixt
#TODO

#mkdir letsencrypt  postgrest  redis  sead_query_api  sqs_mongodb  sqs_nginx  sqs_postgresql  sqs_postgrest  sqs_viewstate_server  traefik

#Build docker images
echo "Building MongoDB image"
docker build -t sqs_mongodb mongodb/docker

echo "Building PostgresSQL/PostGIS image"
#TODO: Get a db dump here from somewhere and load it
docker build -t sqs_postgresql postgresql/docker

echo "Building PostgREST image"
docker build -t sqs_postgrest postgrest/docker

echo "Building SEAD Viewstate Server image"
mkdir -o sqs_viewstate_server/docker
wget https://raw.githubusercontent.com/humlab-sead/sqs_viewstate_server/master/docker/Dockerfile -O sqs_viewstate_server/docker/Dockerfile
docker build -t sqs_viewstate_server sqs_viewstate_server/docker

echo "Building Nginx image"
docker build -t sqs_nginx sqs_nginx/docker

echo "Building SEAD Query API image"
mkdir -p sead_query_api
wget https://raw.githubusercontent.com/humlab-sead/sead_query_api/master/docker/Dockerfile -O sead_query_api/Dockerfile
docker build -t sead_query_api:latest -f sead_query_api/Dockerfile sead_query_api/conf



#Verify that necessary config files exixt?


function askContinue {
	echo "Continue? Y/n"
	read cont

	if [ "$cont" = "n" ]
	then
		echo "Exiting!";
		exit 1;
	fi

	echo "Continuing";
}

echo "hello! continue? Y/n"


#Build docker images
echo "Building MongoDB image"
docker build -t mongodb mongodb/docker
askContinue


echo "Building PostgresSQL/PostGIS image"
#TODO: Get a db dump here from somewhere and load it
docker build -t sqs_postgresql postgresql/docker
echo "Starting postgres for import of database"
docker run -d -p "5432:5432" sqs_postgresql

#We need to wait here since it will take a while before the postgresql server is ready for connections and the above run command will return before it is

until pg_isready -h localhost -p 5432 -q
do
	echo "Waiting for postgres to come up"
	sleep 2
done

echo "Postgres is up, now proceeding with creation of the database"


#Fetch from...
#pg_dump -h localhost -p 5432 -U postgres -F c --quote-all-identifiers sead_production > sead_production-2020-05-19.dump
psql -h localhost -p 5432 -U postgres < postgresql/create_db_and_users.sql
pg_restore -h localhost -p 5432 -U postgres -d postgresql/sead sead_production-2020-05-19.dump

echo "PostgreSQL built and loaded"
askContinue

echo "Building PostgREST image"
docker build -t sqs_postgrest postgrest/docker
cp postgrest/mounts/conf/postgrest.conf.example postgrest/mounts/conf/postgrest.conf
postgrestPass=`date | sha256sum | cut -c1-64`
sed -i s/POSTGREST_PASSWORD/$postgrestPass/g postgrest/mounts/conf/postgrest.conf
cp postgrest/create_user.sql.template postgrest/create_user.sql
echo "ALTER ROLE postgrest WITH PASSWORD '$postgrestPass';" >> postgrest/create_user.sql
psql -h localhost -p 5432 -U postgres sead < postgrest/create_user.sql
askContinue

echo "Building SEAD Viewstate Server image"
mkdir -o sqs_viewstate_server/docker
wget https://raw.githubusercontent.com/humlab-sead/sqs_viewstate_server/master/docker/Dockerfile -O sqs_viewstate_server/docker/Dockerfile
docker build -t sqs_viewstate_server sqs_viewstate_server/docker
askContinue

echo "Building Nginx image"
docker build -t sqs_nginx nginx/docker
askContinue

echo "Building SEAD Query API image"
mkdir -p sead_query_api
wget https://raw.githubusercontent.com/humlab-sead/sead_query_api/master/docker/Dockerfile -O sead_query_api/Dockerfile
docker build -t sead_query_api:latest -f sead_query_api/Dockerfile sead_query_api/conf



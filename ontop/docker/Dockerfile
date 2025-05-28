FROM ontop/ontop:5.3.0

USER root

ADD postgresql-42.7.5.jar /opt/ontop/lib/postgresql-42.7.5.jar

RUN chmod 644 /opt/ontop/lib/postgresql-42.7.5.jar

# Add the entrypoint script
ADD ontop-entrypoint.sh /opt/ontop/ontop-entrypoint.sh
RUN chmod +x /opt/ontop/ontop-entrypoint.sh

USER ontop

# Set the environment variable for the JDBC driver
ENV ONTOP_JDBC_DRIVER=org.postgresql.Driver

ENTRYPOINT ["/bin/bash", "/opt/ontop/ontop-entrypoint.sh"]
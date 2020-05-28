if [ $NO_SSL ]
then
	echo "Starting server without SSL"
	/usr/sbin/nginx && sleep infinity
else
	echo "Starting server with SSL"
	echo "Retrieving cert for domain $DOMAIN with email $ADMIN_EMAIL\n" && /usr/sbin/nginx && certbot --non-interactive --email $ADMIN_EMAIL --text --agree-tos --nginx --domains $DOMAIN && sleep infinity
fi


<?php

/**
 * The dev IdP's configuration: SimpleSAMLphp's defaults (config.php.dist) with the
 * few settings a local IdP behind the router needs.
 */

require __DIR__ . '/config.php.dist';

$idpHost = getenv('SAML_DEV_IDP_HOST') ?: 'sead-idp.local';

// The IdP sits behind the router and the host nginx; it is reached as https://<host>/
$config['baseurlpath'] = 'https://' . $idpHost . '/simplesaml/';
$config['trusted.url.domains'] = [$idpHost];

// Dev only. The salt and admin password come from .env; neither protects anything real.
$config['secretsalt'] = getenv('SAML_DEV_IDP_SECRET_SALT') ?: 'sead-idp-dev-salt';
$config['auth.adminpassword'] = getenv('SAML_DEV_IDP_ADMIN_PASSWORD') ?: bin2hex(random_bytes(16));
$config['admin.checkforupdates'] = false;

$config['technicalcontact_name'] = 'SEAD';
$config['technicalcontact_email'] = 'support@humlab.umu.se';
$config['timezone'] = 'Europe/Stockholm';

$config['enable.saml20-idp'] = true;
$config['module.enable'] = [
    'core' => true,
    'admin' => true,
    'saml' => true,
    'exampleauth' => true,
];

$config['session.cookie.secure'] = true;

$config['logging.handler'] = 'stderr';
$config['logging.level'] = \SimpleSAML\Logger::INFO;

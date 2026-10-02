<?php

/**
 * The dev IdP itself. Its entityID is its metadata URL, which is also what the SP's
 * <SSO entityID> in router/shibboleth/shibboleth2.local.xml.template names.
 */

$idpHost = getenv('SAML_DEV_IDP_HOST') ?: 'sead-idp.local';

$metadata['https://' . $idpHost . '/simplesaml/module.php/saml/idp/metadata'] = [
    'host' => '__DEFAULT__',

    'privatekey' => 'idp.key',
    'certificate' => 'idp.crt',

    'auth' => 'sead-personas',

    // Published as shibmd:Scope; the SP accepts scoped attributes only within it
    'scope' => ['sead-idp.local'],

    // Attribute names are urn:oid / urn:oasis names, as SWAMID IdPs send them
    'attributes.NameFormat' => 'urn:oasis:names:tc:SAML:2.0:attrname-format:uri',
];

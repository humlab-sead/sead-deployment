<?php

/**
 * The one SP this IdP knows: the router on $DOMAIN. Nothing is registered by hand -
 * the entityID and ACS come from DOMAIN, and the SP's certificates from the SP key
 * directory (router/mounts/shibboleth-keys, mounted read-only).
 */

$domain = getenv('DOMAIN') ?: 'sead.local';
$spKeyDir = '/var/simplesamlphp/sp-keys';

$readCertificate = function (string $file) use ($spKeyDir): ?string {
    $path = $spKeyDir . '/' . $file;
    if (!is_readable($path)) {
        return null;
    }
    // The base64 body of the PEM, as metadata wants it
    return preg_replace('/-----[^-]+-----|\s+/', '', file_get_contents($path));
};

$keys = [];
if ($certificate = $readCertificate('sp-signing-cert.pem')) {
    $keys[] = ['type' => 'X509Certificate', 'signing' => true, 'encryption' => false, 'X509Certificate' => $certificate];
}
$encryptionCertificate = $readCertificate('sp-encrypt-cert.pem');
if ($encryptionCertificate) {
    $keys[] = ['type' => 'X509Certificate', 'signing' => false, 'encryption' => true, 'X509Certificate' => $encryptionCertificate];
}

$metadata['https://' . $domain . '/shibboleth'] = [
    'AssertionConsumerService' => [
        [
            'Binding' => 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST',
            'Location' => 'https://' . $domain . '/Shibboleth.sso/SAML2/POST',
            'index' => 1,
        ],
    ],
    'keys' => $keys,
    // SWAMID IdPs encrypt assertions to the SP's encryption key; so does this one
    'assertion.encryption' => $encryptionCertificate !== null,
    'NameIDFormat' => 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient',
    'attributes.NameFormat' => 'urn:oasis:names:tc:SAML:2.0:attrname-format:uri',
];
